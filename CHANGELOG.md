## 0.1.0

* Initial release: traces, metrics and logs over OTLP/HTTP protobuf.
* Offline disk queue with circuit breaker; flush-to-disk on app background.
* Automatic capture: Flutter and uncaught errors, screen views, slow/frozen
  frames, UI-thread stalls, app start, sessions, lifecycle events.
* `OtelHttpClient` with W3C trace propagation.
