# immunoops_flutter

Telemetria do Immuno Ops para apps Flutter. Crashes, telas, jank, tempo de
abertura, rede, aparelho e jornadas de negócio chegam ao console sem código
de medição no app.

Os dados aparecem na tela **Instrumentação** do console, na linha da
conexão do app: **Logs** (erros, ao vivo) e **Ver telemetria** (métricas e
eventos por período).

Plataformas: Android, iOS e macOS; web em modo reduzido. Dart 3.5+ e
Flutter 3.24+ ([compatibilidade](doc/compatibility.md)).

## Integração

Passo a passo completo, com Android, iOS (manifesto de privacidade), web,
jornadas e os problemas já vistos: [doc/setup.md](doc/setup.md). O resumo:

1. Gere a chave na tela Instrumentação do console (vale só no ambiente do
   console que a gerou: use o endpoint que ele mostra).
2. Adicione a dependência ([versões](doc/publishing.md)):

   ```yaml
   dependencies:
     immunoops_flutter: ^0.2.2
   ```

   O pacote está no [pub.dev](https://pub.dev/packages/immunoops_flutter),
   no publisher [immunoops.io](https://pub.dev/publishers/immunoops.io).

3. Três pontos no código:

   ```dart
   // main.dart, logo depois do WidgetsFlutterBinding.ensureInitialized()
   ImmunoOps.init(const ImmunoOpsConfig(
     clientKey: String.fromEnvironment('IMMUNOOPS_CLIENT_KEY'),
     appName: 'cria-app',
     environment: 'production',
   ));

   // no GoRouter e em cada ShellRoute (ou MaterialApp(navigatorObservers:))
   observers: [ImmunoOps.navigatorObserver],

   // em cada Dio
   dio.interceptors.add(ImmunoOpsDioInterceptor());
   ```

4. Confira com o doctor:

   ```sh
   dart run immunoops_flutter:doctor
   dart run immunoops_flutter:doctor --key <chave> --send-test --origin https://app.exemplo.com
   ```

Pontos de atenção:

- **ShellRoute:** cada navigator aceita um observer só; passe um também em
  cada `ShellRoute` / `StatefulShellRoute`. Todos alimentam o mesmo
  rastreador de telas.
- **Outros handlers de erro:** configure-os antes do `init`. O SDK guarda
  os anteriores e repassa cada erro a eles; um definido depois desliga a
  captura (`IMMUNO-W105`).
- **Pacote `http`:** use `ImmunoOpsHttpClient()` no lugar de `http.Client()`.
- **Abertura do app:** o `init` não espera nada. Os hooks de erro entram na
  hora; plugins, disco e timers sobem em segundo plano (`await
  ImmunoOps.ready`, se precisar).

## Jornadas de negócio

Cada execução de um fluxo que importa (checkout, reserva) vira uma jornada:
duração e resultado em `journey.duration_ms`, e erros e requisições no meio
dela levam o nome da jornada.

```dart
final checkout = ImmunoOps.startJourney('checkout.payment',
    attributes: {'payment.method': 'pix'});
try {
  await payments.pay(order);
  checkout.end();
} catch (e, s) {
  checkout.fail(e, s);
  rethrow;
}

// ou
await ImmunoOps.journey('aula.reserva', () => bookings.book(aula));
```

Jornada sem fim em 10 minutos (`journeyTimeout`) ou ao começar outra
sessão conta como `abandoned`.

## O que é coletado

Nomes e atributos completos em [doc/instrumentation.md](doc/instrumentation.md).
Os atributos seguem as convenções do OpenTelemetry onde elas existem
([ADR-002](doc/architecture/ADR-002-opentelemetry.md)).

| Captura | Como chega |
| --- | --- |
| Erros | Log com `event.type` `mobile.crash` (não tratado) ou `mobile.error`, `exception.type`, `exception.message`, `exception.stacktrace`, `exception.fingerprint`, `screen.name`, `journey.name`. No máximo 5 por minuto por erro igual. |
| Rede | `http.client.request.duration_ms` com `http.request.method`, `http.response.status_code`, `server.address`, `url.template` e `error.type` (`timeout`, `dns_error`, `tls_error`, `connection_error` ou o código). 5xx e falhas: log `mobile.network.error` com `trace_id`; 429: aviso; 401/403: só métrica. |
| Jornadas | `journey.duration_ms` por `journey.name` e `journey.outcome`; falha gera log `mobile.journey.failure`. |
| Telas | Evento `screen_view` e `ui.screen.duration_ms`. Só rotas de página; ids na rota viram `:id`. Nome: o da rota; sem nome (`pageBuilder`), o endereço do `Router` (`/login`) ou, sem Router, o tipo do widget da tela. |
| Frames | `ui.frames.total`, `.slow`, `.frozen`, `ui.frame.jank_ratio`, `ui.frame.worst_ms` por tela. |
| Abertura | `app.startup.duration_ms` com `startup.type` `cold` (init → primeiro frame) ou `warm` (volta ao primeiro plano). |
| Memória | `app.memory.rss_mb`; aviso de pouca memória do sistema, com o app em primeiro plano, vira evento `memory_pressure` e log `mobile.memory.pressure`. |
| Aparelho | `device.battery.level`; `connectivity_change`, `network_lost`, `network_restored`. |
| Sessões | `session_start` (com `session.previous_id`), `app_background`, `app_foreground`. |
| Autodiagnóstico | `immunoops.sdk_handshake` 30 s depois do init. |

Toda métrica leva `service.name`, `service.version`, `app.build`,
`platform`, `os.name`, `os.version`, `device.model.identifier`,
`deployment.environment.name` e `telemetry.sdk.version`. Logs e eventos
levam também `session.id` e `app.installation.id`, aleatórios.

Requisições para os hosts em `traceHosts` levam `traceparent` (W3C) e
`tracestate: immunoops=s:<sessão>`, para o backend ligar o trace à sessão.

## API manual

```dart
ImmunoOps.metric('checkout_latency_ms', 420, tags: {'metodo': 'pix'});
ImmunoOps.increment('aula_reservada');
await ImmunoOps.time('carregar_agenda_ms', () => repo.agenda());
ImmunoOps.event('aula_comprada', {'aulaId': 'aula_123', 'valor': 89.90});
ImmunoOps.info('agenda sincronizada', context: {'itens': 12});
ImmunoOps.error(e, stackTrace, {'tela': 'pagamento'});
ImmunoOps.setScreen('aba_perfil');          // navegação fora de um navigator
ImmunoOps.setGlobalTag('plano', 'premium'); // valores poucos, nunca um id
await ImmunoOps.flush();
```

## Configuração (`ImmunoOpsConfig`)

| Opção | Padrão | Para quê |
| --- | --- | --- |
| `clientKey`, `appName` | obrigatórias | Chave e nome da conexão. Sem elas o SDK fica desligado e o app segue. |
| `environment` | `production` | Separa produção, staging e desenvolvimento. |
| `endpoint` | `https://aegis.funccloud.com/agent/ingest` | O endereço que o console mostra junto da chave. |
| `captures` | tudo ligado | `ImmunoOpsCaptures(device: false, ...)` desliga uma captura. |
| `sampling` | 1 (tudo) | Fração mantida de métricas, logs, eventos e rede. Logs de erro nunca saem. |
| `traceHosts` | vazio | Hosts que recebem `traceparent`/`tracestate`. Vazio por padrão: cabeçalho extra numa API de terceiros quebra o CORS na web. |
| `flushInterval` | 10 s | Intervalo de envio; ir para segundo plano envia na hora. |
| `maxBatchSize` / `maxQueueSize` | 100 / 2000 | Itens por envio e teto da fila; cheia, os mais antigos saem. |
| `deviceInterval` | 60 s | Amostragem de memória e bateria. |
| `sessionTimeout` | 30 min | Tempo em segundo plano que encerra a sessão. |
| `journeyTimeout` | 10 min | Jornada aberta além disso conta como abandonada. |
| `sanitizePii` | `true` | Mascara dados pessoais antes do envio. |
| `requireConsent` | `false` | Nada é coletado até `ImmunoOps.setConsent(true)`. |
| `enabled` | `true` | Desliga o SDK por completo. |
| `debug` | `false` | Imprime cada lote e cada diagnóstico. |

## Entrega, falhas e privacidade

- Lotes em `POST {endpoint}/v1/custom`, só com `Authorization` e
  `Content-Type`.
- Sem rede, 429 ou 5xx: os itens ficam na fila e no disco e voltam com
  espera crescente (5 s até 5 min). Sobrevivem a um reinício.
- 401/403: chave recusada; o envio para até o app reiniciar (`IMMUNO-E001`).
- O SDK nunca derruba o app: handlers do app são sempre chamados, falha
  interna vira diagnóstico, valor que não vira JSON é convertido.
- Mascaramento no aparelho: CPF, cartão, e-mail, tokens, query string de
  URLs e chaves sensíveis. Nada de nome, telefone, IP ou id do aparelho; da
  rede, só tempo, código, método, host e rota como template
  ([ADR-003](doc/architecture/ADR-003-privacy-security.md)).
- Lojas: declare *Crash Data* e *Performance Data* (sem vínculo ao usuário,
  sem rastreamento) no `PrivacyInfo.xcprivacy` e na App Store; os mesmos
  tipos no Data Safety do Google Play.

Custo medido por chamada: 3 a 6 µs para métrica, log e evento
([doc/overhead.md](doc/overhead.md)).

## Doctor

`dart run immunoops_flutter:doctor` verifica o app antes do build.

| Código | Verifica |
| --- | --- |
| D001–D004 | Dependência, versão do Dart, conflitos de versão, `pubspec.lock` |
| D010 | `ImmunoOps.init` presente e antes do `runApp` |
| D011 | `navigatorObserver` registrado, inclusive em ShellRoute |
| D012 / D013 | Cada `Dio(` com interceptor; chamadas do pacote `http` sem wrapper |
| D014 | Outros handlers globais de erro |
| D020 / D021 | Android: `INTERNET` no manifesto principal, `minSdk` |
| D022 | iOS: dados de crash e desempenho declarados |
| D023 / D044 | Web: origem liberada no CORS e preflight com 2xx |
| D024 | Android: plugin resolvido que o Android Gradle plugin do app não compila |
| D030 | Build ofuscado: guardar os símbolos de cada versão |
| D040–D043 | Chave, endpoint alcançável, envio de teste (`--send-test`) |

`--ci` termina com código 1 se houver erro; `--json` imprime em JSON.

## Códigos de diagnóstico

`ImmunoOps.diagnostics()` devolve as capturas ativas e os problemas; em
debug eles também saem no console.

| Código | Significado | O que fazer |
| --- | --- | --- |
| IMMUNO-E001 | Chave recusada (401/403) | Copiar a chave de novo no console |
| IMMUNO-E002 | Ingestão inacessível; reenviando | Conferir endpoint, rede e CORS |
| IMMUNO-E003 | Lote recusado e descartado | Atualizar o SDK |
| IMMUNO-E004 | SDK usado antes do `init` | Chamar `init` no `main()` |
| IMMUNO-E005 | Falha ao iniciar | Rodar o doctor |
| IMMUNO-W101 | Nenhuma navegação em 30 s | Registrar `navigatorObserver` |
| IMMUNO-W102 | Nenhuma requisição em 30 s | Interceptor em cada Dio |
| IMMUNO-W103 | Plugin nativo ausente | `flutter clean` e reinstalar o app |
| IMMUNO-W104 | Fila cheia, itens antigos descartados | Ver E002; ajustar fila ou sampling |
| IMMUNO-W105 | Outro código substituiu o handler de erro | Configurar outras ferramentas antes do `init` |
| IMMUNO-I201 | Consentimento pendente | `ImmunoOps.setConsent(true)` |

## Limitações

- ANR, crash nativo e OutOfMemory não são capturados: exigem código nativo
  (v2, [ADR-001](doc/architecture/ADR-001-sdk-modularity.md)).
- A abertura cold começa no `init`, não no início do processo.
- Builds com `--obfuscate` enviam stack traces ofuscados; a desofuscação no
  servidor ainda não existe.
- O SDK propaga o contexto de trace mas ainda não envia spans.
- Na web, a ingestão responde 405 ao preflight (OPTIONS) e o navegador
  bloqueia o envio até o backend corrigir isso; a origem do app também
  precisa estar em `AEGIS_CORS_ORIGINS`.

## Documentação

- [Setup num app](doc/setup.md)
- [Arquitetura (ADRs)](doc/architecture/)
- [Instrumentação: sinais e atributos](doc/instrumentation.md)
- [Compatibilidade](doc/compatibility.md)
- [Simulação do incidente de checkout](doc/simulation.md)
- [Custo no app](doc/overhead.md)
- [Publicação e versões](doc/publishing.md)

## Desenvolvimento

```sh
flutter test                                          # unitários
flutter test benchmark/                               # custo por chamada
cd example && flutter create --platforms=android,ios,macos .
flutter test integration_test -d <dispositivo>        # incidente de ponta a ponta
```
