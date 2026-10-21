# ADR-002: convenções do OpenTelemetry sobre o transporte do Immuno Ops

**Status:** aceito · 2026-10-19

## Contexto

O documento de simulação pede que os campos sigam as convenções semânticas
do OpenTelemetry e que o envio seja OTLP/HTTPS. O console do Immuno Ops,
porém, lê a telemetria de aplicações de `POST /agent/ingest/v1/custom`
(ClickHouse), em JSON próprio (`IngestTelemetryPayload`); o pipeline OTLP
existente (`/v1/metrics`, `/v1/logs`) não alimenta essas telas.

## Decisão

1. **Nomes:** os atributos seguem o OpenTelemetry onde existe convenção,
   e o resto tem nome do Immuno Ops, listado em `docs/instrumentation.md`.
   Exemplos: `service.name`, `service.version`,
   `deployment.environment.name`, `os.*`, `device.*`,
   `app.installation.id`, `session.id`, `http.request.method`,
   `http.response.status_code`, `server.address`, `url.template`,
   `error.type`, `exception.*`.
2. **Transporte:** JSON em `/agent/ingest/v1/custom`, o que o console lê
   hoje. Mudar para OTLP é trocar o `IngestExporter`, sem mexer em captura
   nem em nomes.
3. **Unidades:** durações em milissegundos, com o sufixo `_ms` no nome
   (`http.client.request.duration_ms`). O OpenTelemetry usa segundos; o
   console mostra o valor cru, e milissegundo é o que se lê ali.
4. **Contexto de trace:** W3C `traceparent` nas requisições para os hosts
   que o app liberar (`traceHosts`), mais `tracestate: immunoops=s:<sessão>`
   para o backend ligar o trace à sessão do app. O `trace_id` vai no log do
   erro de rede.

## Pendências

- O SDK ainda não envia spans; a correlação app → API depende do backend
  continuar o trace (ver backlog IMOB-016).
- `screen.name`, `journey.*` e `event.type` não têm convenção estável no
  OpenTelemetry; revisar quando houver.
