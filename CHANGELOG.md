## 0.2.0

Alinhamento com o planejamento do SDK mobile (backlog IMOB e documento de
simulação de incidentes), adaptado de Kotlin para Flutter.

- Módulos internos com a estrutura planejada: `core` (com `lifecycle`,
  `context`, `privacy`), `crash`, `network`, `performance`, `rum`,
  `exporter`. `ImmunoOpsOptions` passa a se chamar `ImmunoOpsConfig`.
- Jornadas de negócio: `ImmunoOps.startJourney` / `ImmunoOps.journey`, com
  `journey.duration_ms` por resultado e o nome da jornada em erros e
  requisições (IMOB-019/020).
- Rede: DNS e TLS separados de outras falhas; 5xx e falhas como erro,
  429 como aviso, 401/403 só métrica; `tracestate` com a sessão
  (IMOB-014/015).
- Abertura warm, pressão de memória, rede perdida e restaurada, sessão
  anterior ligada à nova.
- Atributos nas convenções do OpenTelemetry e `event.type` por tipo de
  sinal. Quebra os nomes da 0.1.0 (ver `docs/instrumentation.md`).
- Documentação: ADRs, instrumentação, compatibilidade, publicação,
  simulação do incidente e custo medido.
- App de exemplo como loja com checkout reproduzindo o incidente, e teste
  de ponta a ponta em Android, iOS e macOS.
- CI do pacote (`.github/workflows/sdk-flutter.yml`).

## 0.1.0

Primeira versão, para o piloto no app CRIA.

- Captura automática de erros, telas, frames, tempo de abertura, rede (Dio e
  `http`), aparelho e sessões.
- API manual igual à do SDK Node: `metric`, `increment`, `time`, logs,
  `error`, `event`.
- Fila com envio em lotes, espera crescente, persistência em disco e
  descarte dos itens mais antigos quando cheia.
- Mascaramento de dados pessoais e consentimento LGPD.
- Autodiagnóstico em execução (`ImmunoOps.diagnostics()`) e evento de
  handshake para o console.
- `dart run immunoops_flutter:doctor` para verificar a integração antes do
  build.
