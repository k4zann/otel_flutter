# http-client Specification

## Purpose

Trace outgoing HTTP requests made with package:http and link them to backend traces through W3C headers.

## Requirements

### Requirement: Client spans
Each request through `OtelHttpClient` SHALL produce a CLIENT span named by the HTTP method, with `http.request.method`, `url.full`, `url.scheme`, `server.address`, `server.port` (default 443 for https, 80 for http) and `http.response.status_code`. Responses with status 400 or higher SHALL set `error.type` to the status code and status `error`. Exceptions SHALL be recorded on the span, set `error.type` to the exception type, and be rethrown.

#### Scenario: Not found
- **WHEN** a GET request returns 404
- **THEN** the span has status `error` and `error.type = 404`

#### Scenario: Connection reset
- **WHEN** the inner client throws `ClientException`
- **THEN** the span has an `exception` event, `error.type = ClientException`, and the caller receives the exception

### Requirement: URL redaction
`url.full` SHALL exclude user info and fragment, and SHALL exclude the query string unless query capture is enabled.

#### Scenario: Secret in query
- **WHEN** `https://user:pw@api.example.com/items?token=secret#x` is requested
- **THEN** `url.full` is `https://api.example.com/items`

### Requirement: Context propagation
The request SHALL carry `traceparent` (and `tracestate` / `baggage` when present) identifying the request's span, unless the propagation filter returns false for the URL.

#### Scenario: Header matches span
- **WHEN** a traced request is sent
- **THEN** the span id in its `traceparent` header equals the exported client span's id

### Requirement: Request duration metric
Every request SHALL record histogram `http.client.request.duration` in seconds, with the semantic-convention buckets and attributes `http.request.method`, `server.address`, `server.port`, `http.response.status_code` and `error.type` when applicable.

#### Scenario: Successful request
- **WHEN** a request completes with 200
- **THEN** one value is recorded with unit `s` and status code 200
