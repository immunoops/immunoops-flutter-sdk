# Simulação: incidente INC-ANDROID-204 no Flutter

Adaptação do documento "ImmunoOps Android SDK — Simulação de erros e
incidentes" ao SDK Flutter. O app de exemplo (`example/`) é a loja do
cenário: um checkout com a jornada `checkout.payment`.

## Linha do tempo e como reproduzir

| Hora | Evento do documento | No exemplo | O que o SDK registra |
| --- | --- | --- | --- |
| 09:10 | Versão publicada | build do exemplo | `service.version` em todo dado |
| 09:15 | Degradação, P95 sobe | Pagar: `slow` | `journey.duration_ms` alto, outcome `success` |
| 09:18 | SocketTimeoutException | Pagar: `timeout` | log `mobile.network.error`, `error.type: timeout`, `journey.name`, `trace_id` |
| 09:20 | ANR | — | não capturado na v1 (nativo) |
| 09:22 | 504 no pagamento | Pagar: `gateway504` | log `mobile.network.error`, `http.response.status_code: 504` |
| — | Crash no checkout | Pagar: `crash` | log `mobile.journey.failure` com `exception.*` |
| — | Pressão de memória | Simular pressão de memória | evento `memory_pressure`, log `mobile.memory.pressure` |
| 09:25 | SLO da jornada violado | — | `journey.duration_ms` por outcome; alerta é do console (IMOB-031) |
| 09:30 | Trace liga app e backend | — | `traceparent` e `tracestate: immunoops=s:<sessão>` na requisição |

## Validação automática

`example/integration_test/end_to_end_test.dart` roda success, timeout, 504
e crash no checkout, mais pressão de memória, contra um servidor local, e
verifica:

- uma jornada `success` e três `failure`;
- os erros de rede dentro da jornada, com `trace_id`;
- a mesma `session.id` nos logs e no `tracestate` recebido pela "API";
- `service.version` e `os.version` em toda métrica.

```sh
cd example
flutter create --platforms=android,ios,macos .
flutter test integration_test -d <dispositivo>
```

No Android, libere `android:usesCleartextTraffic="true"` no manifesto do
exemplo para o servidor local em HTTP.

## Indicadores do documento e de onde saem

| Indicador | Fonte |
| --- | --- |
| Crash-free sessions | `session_start` e logs `mobile.crash` por `session.id` (cálculo no console, IMOB-030) |
| Taxa de ANR | v2 |
| Checkout P95 | `journey.duration_ms` com `journey.name = checkout.payment` |
| HTTP 5xx | `http.client.request.duration_ms` por `http.response.status_code` |
