# Instrumentação: sinais e atributos

Fonte única dos nomes: `lib/src/core/semconv.dart`. "OTel" marca nomes das
convenções do OpenTelemetry; os demais são do Immuno Ops.

## Atributos comuns

| Atributo | Origem | Em métricas | Em logs e eventos |
| --- | --- | --- | --- |
| `service.name` (OTel) | `appName` | sim | sim |
| `service.version` (OTel) | versão do app | sim | sim |
| `app.build` | build do app | sim | sim |
| `deployment.environment.name` (OTel) | `environment` | sim | sim |
| `platform` | android, iOS, web... | sim | sim |
| `os.name`, `os.version` (OTel) | sistema | sim | sim |
| `device.model.identifier` (OTel) | modelo | sim | sim |
| `telemetry.sdk.version` (OTel) | versão do SDK | sim | sim |
| `device.manufacturer` (OTel) | fabricante | não | sim |
| `telemetry.sdk.name`, `telemetry.sdk.language` (OTel) | `immunoops-flutter`, `dart` | não | sim |
| `session.id` (OTel) | sessão, aleatório | não | sim |
| `app.installation.id` (OTel) | instalação, aleatório | não | sim |

Ids ficam fora das métricas para não explodir a cardinalidade.

## `event.type` dos logs

| Valor | Quando | Nível |
| --- | --- | --- |
| `mobile.crash` | Erro que nada no app tratou | error |
| `mobile.error` | Erro tratado (`ImmunoOps.error`) ou erro do framework | error |
| `mobile.network.error` | 5xx, timeout, DNS, TLS, falha de conexão | error |
| `mobile.network.error` | 429 | warn |
| `mobile.journey.failure` | Jornada terminou em `fail` | error |
| `mobile.memory.pressure` | Aviso de pouca memória do sistema | warn |

401 e 403 viram só métrica: um 401 esperado não deve abrir incidente.

## Erros

Log com `exception.type`, `exception.message`, `exception.stacktrace`
(OTel), `exception.unhandled`, `exception.source`, `exception.fingerprint`
(agrupa o mesmo erro), `flutter.library`, `flutter.context`,
`screen.name` e `journey.name`. O mesmo fingerprint vai no máximo 5 vezes
por minuto.

## Rede

Métrica `http.client.request.duration_ms` com `http.request.method`,
`http.response.status_code`, `server.address`, `url.template` e
`error.type` (OTel), mais `journey.name`. `error.type` vale o código HTTP
(≥ 400) ou `timeout`, `dns_error`, `tls_error`, `connection_error`,
`cancelled`. O log de erro de rede leva também `duration_ms`,
`exception.type`, `trace_id`, `span_id` e `screen.name`.

## Jornadas

`ImmunoOps.startJourney('checkout.payment', attributes: {...})` e
`end()` / `fail(e, s)` / `abandon()`, ou `ImmunoOps.journey(nome, ação)`.

- Métrica `journey.duration_ms` com `journey.name`, `journey.outcome`
  (`success`, `failure`, `abandoned`) e os atributos da jornada.
- Eventos `journey_start` e `journey_end`.
- Abertas há mais de `journeyTimeout` (10 min) ou ao começar outra sessão:
  `abandoned`.

## Performance

| Métrica | Atributos |
| --- | --- |
| `app.startup.duration_ms` | `startup.type`: `cold` (init → primeiro frame), `warm` (volta ao primeiro plano → próximo frame) |
| `ui.frames.total`, `ui.frames.slow`, `ui.frames.frozen` | `screen.name` |
| `ui.frame.jank_ratio`, `ui.frame.worst_ms` | `screen.name` |
| `app.memory.rss_mb` | — |
| `device.battery.level` | `battery.state` |
| `ui.screen.duration_ms` | `screen.name` |

## Eventos

`session_start` (`session.previous_id`), `app_background`
(`foreground_ms`), `app_foreground` (`background_ms`), `screen_view`
(`screen.name`, `screen.previous_name`), `connectivity_change`,
`network_lost`, `network_restored` (`duration_ms`), `memory_pressure`,
`journey_start`, `journey_end`, `immunoops.sdk_handshake`.
