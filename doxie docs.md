# Doxie Q / Doxie Go SE Wi-Fi API — AI Client Specification

Source: Apparent Corporation, *HTTP/JSON API Developer Guide*, Nov. 29, 2017. The API is HTTP/JSON over port 80 and is intended for Doxie Q and Doxie Go SE Wi-Fi only. Here you can find the original PDF: https://help.getdoxie.com/doxieq/wifi/api/

## 1. Connection

Doxie exposes an HTTP API on port `80`.

### Direct Wi-Fi / AP mode

When Doxie creates its own Wi-Fi network:

* Default network name resembles `Doxie_042D6A`.
* Default API host: `10.10.100.1`
* Base URL: `http://10.10.100.1`

The scanner must have its Wi-Fi module enabled and ready.

### Client/network mode

Doxie can join an existing Wi-Fi network using the Doxie desktop or iOS app.

* Obtain its IP through DHCP or its configured static IP.
* API remains on port `80`.
* Base URL: `http://<scanner-ip>`

The API itself cannot configure Doxie to join a network. 

## 2. Discovery

Doxie supports SSDP/UPnP.

It periodically broadcasts SSDP `NOTIFY` messages and responds to matching `M-SEARCH` requests. SSDP packets contain the model number and Wi-Fi firmware version, e.g.:

* `DoxieDX300/1.0`
* `DoxieDX255/1.08`

In direct-network mode, simply trying `10.10.100.1` may be easier than SSDP discovery. 

## 3. Authentication

Authentication is disabled by default.

If a password has been configured through the Doxie desktop/iOS app:

* Use HTTP Basic Authentication.
* Username is always `doxie`.
* Password is the scanner's configured password.
* `GET /hello.json` remains unauthenticated.
* All other API commands require authentication.

Missing or incorrect credentials produce HTTP `401 Unauthorized`. 

Client implementation should therefore:

```text
GET /hello.json
→ inspect hasPassword
→ if true, send Basic Auth username "doxie" + configured password
→ otherwise make unauthenticated requests
```

## 4. Scanner status

### `GET /hello.json`

Returns scanner and network information.

Example:

```json
{
  "model": "DX255",
  "name": "Doxie_3c7fb4",
  "firmware": "0.17",
  "firmwareWiFi": "0108",
  "hasPassword": true,
  "MAC": "74:72:f2:3c:7f:b4",
  "mode": "AP",
  "network": "Apparent",
  "ip": "192.168.0.100"
}
```

Fields:

| Field          | Meaning                                                                    |
| -------------- | -------------------------------------------------------------------------- |
| `model`        | `DX300` = Doxie Q; `DX255` = Doxie Go SE                                   |
| `name`         | Scanner name, normally `Doxie_XXXXXX`                                      |
| `firmware`     | Scanner firmware version                                                   |
| `firmwareWiFi` | Wi-Fi firmware version                                                     |
| `hasPassword`  | Whether API authentication is configured                                   |
| `MAC`          | Scanner MAC address                                                        |
| `mode`         | `AP` = scanner creates network; `Client` = scanner joined existing network |
| `network`      | Network name when in `Client` mode                                         |
| `ip`           | Scanner IP when in `Client` mode                                           |

`/hello.json` does not require authentication. 

## 5. Restart Wi-Fi

### `GET /restart.json`

Restarts the scanner's Wi-Fi system.

Successful response:

```text
HTTP 204 No Content
```

The request does not return a JSON body. The client should expect the connection to disappear temporarily and wait for the scanner to become reachable again. 

## 6. List scans

### `GET /scans.json`

Returns all scans currently stored in scanner memory.

Example:

```json
[
  {
    "name": "/DOXIE/JPEG/IMG_0001.JPG",
    "size": 241220,
    "modified": "2017-05-01 00:10:06"
  },
  {
    "name": "/DOXIE/JPEG/IMG_0002.JPG",
    "size": 265085,
    "modified": "2017-05-03 00:09:26"
  },
  {
    "name": "/DOXIE/PDF/IMG_0001.PDF",
    "size": 273522,
    "modified": "2017-05-01 00:09:44"
  }
]
```

Important behavior:

* A newly completed scan may take several seconds to appear.
* Immediately after scanning, `/scans.json` can return a successful HTTP response with an empty body because scanner memory is temporarily busy.
* Retry in that situation. 

## 7. Detect newly created scans

### `GET /scans/recent.json`

Returns the path of the most recent scan:

```json
{
  "path": "/DOXIE/JPEG/IMG_0003.JPG"
}
```

Use this endpoint for polling instead of repeatedly downloading the complete scan list.

A changed `path` indicates a new scan.

If no recent scan exists, response is:

```text
204 No Content
```

This can occur immediately after startup or when there are no scans. 

Recommended polling logic:

```text
previous_path = null

loop:
    GET /scans/recent.json

    if 200:
        path = response.path
        if path != previous_path:
            process new scan
            previous_path = path

    if 204:
        no scan available

    retry after a delay
```

The API documentation does not specify a required polling interval.

## 8. Download a scan

### Doxie Q

```http
GET /scans/DOXIE/JPEG/IMG_XXXX.JPG
GET /scans/DOXIE/PDF/IMG_XXXX.PDF
```

The path must come from `/scans.json` or `/scans/recent.json`, with `/scans` prepended.

Example:

```http
GET http://10.10.100.1/scans/DOXIE/JPEG/IMG_0001.JPG
```

Returns the actual scan file.

A nonexistent path returns `404 Not Found`. 

The API supports JPEG scans for both documented scanner models and PDF scans on Doxie Q. The PDF directory is `/DOXIE/PDF`; JPEG is `/DOXIE/JPEG`. 

## 9. Download thumbnail

### Doxie Q

```http
GET /thumbnails/DOXIE/JPEG/IMG_XXXX.JPG
GET /thumbnails/DOXIE/PDF/IMG_XXXX.PDF
```

The scan path is taken from the scan listing/recent endpoint and `/thumbnails` is prepended.

Thumbnail constraints:

* Maximum bounding dimensions: `240 × 240` pixels.
* Thumbnail generation can lag behind scan availability.
* A newly available scan may therefore return `404 Not Found` for its thumbnail.
* Retry after a delay if this happens. 

## 10. Delete one scan

### `DELETE /scans/<scan-path>`

Examples:

```http
DELETE /scans/DOXIE/JPEG/IMG_0001.JPG
DELETE /scans/DOXIE/PDF/IMG_0001.PDF
```

Success:

```text
204 No Content
```

Missing/error:

```text
404 Not Found
```

Deletion takes several seconds because the scanner must acquire and release a lock on internal storage.

Deletion can fail when the scanner is busy, so retry failure conditions. For multiple files, use the bulk-delete endpoint instead. 

## 11. Delete multiple scans

### `POST /scans/delete.json`

Send a JSON array containing scan paths:

```json
[
  "/DOXIE/JPEG/IMG_0001.JPG",
  "/DOXIE/JPEG/IMG_0002.JPG",
  "/DOXIE/PDF/IMG_0001.PDF"
]
```

Example:

```http
POST /scans/delete.json
Content-Type: application/json

["/DOXIE/JPEG/IMG_0001.JPG","/DOXIE/JPEG/IMG_0002.JPG"]
```

Success:

```text
204 No Content
```

Error:

```text
403 Forbidden
```

This is significantly faster than deleting files individually and should be used for bulk deletion. 

## 12. Minimal client architecture

An AI agent implementing a client should expose approximately these operations:

```text
discover() → scanner address
get_status() → /hello.json
restart_wifi() → /restart.json

list_scans() → /scans.json
get_recent_scan() → /scans/recent.json

download_scan(path) → /scans/<path>
download_thumbnail(path) → /thumbnails/<path>

delete_scan(path) → DELETE /scans/<path>
delete_scans(paths[]) → POST /scans/delete.json
```

Core implementation rules:

1. Default direct-network address is `http://10.10.100.1:80`.
2. In client mode, use the scanner's DHCP/static IP.
3. Discover scanners through SSDP when automatic discovery is required.
4. Always call `/hello.json` first when establishing a connection.
5. `/hello.json` determines the model, network state, IP, firmware, and whether authentication is required.
6. If `hasPassword=true`, authenticate every endpoint except `/hello.json` with HTTP Basic Auth, username `doxie`.
7. Treat `204` as a valid response for endpoints that document it.
8. Retry scan-list/recent/thumbnail operations because newly created scans become available asynchronously.
9. Use `/scans/recent.json` for efficient new-scan detection.
10. Use bulk deletion for multiple scans.
11. Do not assume the scanner can be configured onto a Wi-Fi network through this API.
12. Target only Doxie Q (`DX300`) and Doxie Go SE (`DX255`); the older DX250 API is a different/discontinued implementation.  

### API endpoint summary

| Method   | Endpoint             | Purpose                      | Success       |
| -------- | -------------------- | ---------------------------- | ------------- |
| `GET`    | `/hello.json`        | Scanner status/configuration | `200`         |
| `GET`    | `/restart.json`      | Restart Wi-Fi                | `204`         |
| `GET`    | `/scans.json`        | List all scans               | `200`         |
| `GET`    | `/scans/recent.json` | Get latest scan path         | `200` / `204` |
| `GET`    | `/scans/<path>`      | Download scan                | `200`         |
| `GET`    | `/thumbnails/<path>` | Download thumbnail           | `200`         |
| `DELETE` | `/scans/<path>`      | Delete one scan              | `204`         |
| `POST`   | `/scans/delete.json` | Delete multiple scans        | `204`         |

This specification contains the API behavior documented in the supplied 2017 guide; it does not add undocumented commands or assumptions.
