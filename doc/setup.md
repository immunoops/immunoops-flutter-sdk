# Setup num app

Passo a passo para instrumentar um app Flutter, do zero até os dados no
console. Cada passo diz como conferir. O app piloto foi o CRIA; os
problemas que ele mostrou estão em [Problemas conhecidos](#problemas-conhecidos).

## 1. Chave e endpoint

Na tela **Instrumentação** do console, em "Conectar via SDK", gere a chave
da conexão do app. O console mostra o endpoint junto da chave, e os dois
andam juntos: **uma chave só vale no ambiente que a gerou**.

| Console | Endpoint |
| --- | --- |
| Staging | `https://staging.immunoops.io/agent/ingest` |
| Produção (funccloud) | `https://aegis.funccloud.com/agent/ingest` (padrão do SDK) |

Chave de um ambiente no endpoint do outro dá `HTTP 401: tenant
identification required`. Confira antes de lançar:

```sh
dart run immunoops_flutter:doctor --key <chave> --endpoint <endpoint> --send-test
```

A chave nunca vai para o código nem para arquivo versionado. Duas formas de
passá-la:

- `--dart-define=IMMUNOOPS_CLIENT_KEY=...` (e `IMMUNOOPS_ENDPOINT=...`) no
  `flutter run` / `flutter build`, ou `--dart-define-from-file` com um
  arquivo fora do git.
- Num `.env` que o app já carrega e o git ignora (o CRIA usa
  `flutter_dotenv` com `.env.dev` / `.env.prod`). Deixe as variáveis vazias
  no `.env.example`, para documentar.

Sem chave o SDK fica desligado e o app segue normal: dá para integrar antes
de ter a chave.

## 2. Dependência

Enquanto o SDK muda junto com o app, aponte para a pasta local:

```yaml
dependencies:
  immunoops_flutter:
    path: ../immunoops-flutter-sdk   # relativo ao pubspec.yaml do app
```

`path:` só serve na máquina de quem desenvolve: o build do app em CI ou
Docker não enxerga a pasta. Antes de qualquer build de entrega, troque para
o pacote no pub.dev (publisher
[immunoops.io](https://pub.dev/publishers/immunoops.io)):

```yaml
dependencies:
  immunoops_flutter: ^0.2.2
```

Não precisa de token nem de acesso ao GitHub: o `flutter pub get` baixa
de [pub.dev/packages/immunoops_flutter](https://pub.dev/packages/immunoops_flutter).
Versões e o que cada tag publica estão em [publicação](publishing.md).

Depois do `flutter pub get`, rode o doctor (passo 6): ele acusa conflito de
versão de plugin e plugin que o Android do app não compila.

## 3. Inicialização

No `main`, logo depois do `WidgetsFlutterBinding.ensureInitialized()` e de
carregar o `.env` (se a chave vem dele), antes de Firebase e do `runApp`:

```dart
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Env.load();                       // se a chave vem do .env
  ImmunoOps.init(ImmunoOpsConfig(
    clientKey: const String.fromEnvironment('IMMUNOOPS_CLIENT_KEY').isNotEmpty
        ? const String.fromEnvironment('IMMUNOOPS_CLIENT_KEY')
        : Env.immunoOpsClientKey,
    appName: 'cria-app',
    environment: 'staging',               // staging, production, development
    endpoint: 'https://staging.immunoops.io/agent/ingest',
  ));
  // ... Firebase, DI, runApp
}
```

Quanto mais cedo o `init`, mais erros de inicialização ele pega e mais
fiel fica o tempo de abertura (`app.startup.duration_ms` conta do `init` ao
primeiro frame). O `init` não espera nada: plugins, disco e timers sobem em
segundo plano.

Handlers de erro próprios (`FlutterError.onError`,
`PlatformDispatcher.instance.onError`, Crashlytics) vão **antes** do
`init`: o SDK guarda os anteriores e repassa cada erro. Um definido depois
desliga a captura (`IMMUNO-W105`).

Vale a pena centralizar a configuração num arquivo do app (no CRIA,
`lib/core/telemetry/immunoops_setup.dart`), com o ambiente seguindo o do
app.

## 4. Telas e rede

```dart
// GoRouter, e cada ShellRoute / StatefulShellRoute (cada navigator aceita
// um observer só; ImmunoOps.navigatorObserver devolve um novo a cada uso)
GoRouter(
  observers: [ImmunoOps.navigatorObserver],
  routes: [
    ShellRoute(observers: [ImmunoOps.navigatorObserver], ...),
  ],
);
// ou MaterialApp(navigatorObservers: [ImmunoOps.navigatorObserver])

// cada Dio do app, inclusive os criados soltos (Dio() num widget)
dio.interceptors.add(ImmunoOpsDioInterceptor());

// pacote http
final client = ImmunoOpsHttpClient();   // no lugar de http.Client()
```

Nome das telas: o da rota. Rotas com `pageBuilder:` (go_router) não têm
nome na página; aí o SDK usa o endereço do Router (`/login`,
`/aulas/:id`), sem mudar nada no app. Ids na rota viram `:id`.

`traceHosts` (os hosts da API do app) liga o `traceparent` para o backend
juntar o trace à sessão. Na web, a API precisa aceitar esse cabeçalho no
CORS; senão deixe vazio.

## 5. Jornadas

Os fluxos que importam para o negócio (pagamento, reserva) viram jornadas.
Um nome por fluxo e atributos de poucos valores para separar variações:

```dart
final checkout = ImmunoOps.startJourney('checkout.payment', attributes: {
  'checkout.flow': 'cart',              // cart, monthly, dates
  'payment.method': 'payment_sheet',    // credit, stripe_checkout
});
try {
  await pagar();
  checkout.end();
} on StripeException catch (e, s) {
  // Fechar a tela de pagamento é desistência, não falha.
  e.error.code == FailureCode.Canceled ? checkout.abandon() : checkout.fail(e, s);
} catch (e, s) {
  checkout.fail(e, s);
} finally {
  checkout.abandon();                   // ignorado se já terminou
}
```

- Comece a jornada depois das validações de tela (campo vazio não é
  falha de pagamento).
- Termine em cada ramo: sucesso, erro de API (`fail(error)`), cancelamento.
  O `abandon()` no `finally` fecha o que sobrou; chamadas depois do fim são
  ignoradas.
- Na web com redirecionamento (Stripe Checkout), a página recarrega:
  termine a jornada na saída, com `end(attributes: {'checkout.step':
  'redirect'})`, e meça a confirmação na página de retorno.

## 6. Plataformas

### Android

- `INTERNET` no `AndroidManifest.xml` **principal** (debug tem por conta
  própria; sem ela no main, só o release fica mudo).
- `minSdk` 21 ou mais.
- **Android Gradle plugin (AGP):** `connectivity_plus` 7.1+ pede AGP
  8.9.1+. App em AGP mais velho falha no build com `checkDebugAarMetadata:
  Dependency 'androidx.core:core:1.18.0' requires Android Gradle plugin
  8.9.1 or higher`. Suba o AGP (`com.android.application` em
  `android/settings.gradle`) ou prenda no `pubspec.yaml` do app:

  ```yaml
  connectivity_plus: ">=7.0.0 <7.1.0"
  ```

  O doctor acusa isso (`D024`).

### iOS

- **Deployment target 15.0** no `project.pbxproj`, no `Podfile`
  (`platform :ios, '15.0'`) e, se existir, `MinimumOSVersion` do
  `Flutter/AppFrameworkInfo.plist`. Com o Swift Package Manager (padrão nos
  Flutter recentes), Firebase e outros plugins exigem 15.0, e o build falha
  com "increase your app's minimum platform version from 13.0 to at least
  15.0".
- **Manifesto de privacidade:** a Apple pede os dados coletados declarados
  em `ios/Runner/PrivacyInfo.xcprivacy`. Copie o
  [modelo](templates/PrivacyInfo.xcprivacy) (dados de crash, desempenho e
  diagnóstico, sem vínculo ao usuário e sem rastreamento) e adicione o
  arquivo ao target Runner no Xcode (arrastar para a pasta Runner, com
  "Add to targets: Runner"), para ele entrar em Copy Bundle Resources.
  Confira no app compilado:

  ```sh
  flutter build ios --simulator --debug
  plutil -p build/ios/iphonesimulator/Runner.app/PrivacyInfo.xcprivacy
  ```

  O manifesto descreve o código do app. Plugins e SDKs (Firebase, Stripe,
  Meta) trazem os próprios; não copie para o do app o rastreamento que for
  de um SDK de anúncio. Ajuste `NSPrivacyTracking` se o código do próprio
  app rastrear. Os mesmos dados vão nas informações de privacidade do App
  Store Connect.

### Web

Funciona em modo reduzido (sem memória nem bateria). O navegador só envia
se a origem do app estiver liberada no CORS da API do Immuno Ops
(`AEGIS_CORS_ORIGINS`) e o preflight responder 2xx:

```sh
dart run immunoops_flutter:doctor --key <chave> --endpoint <endpoint> --origin https://app.exemplo.com
```

## 7. Conferir

```sh
dart run immunoops_flutter:doctor
dart run immunoops_flutter:doctor --key <chave> --endpoint <endpoint> --send-test
```

Tudo verde, rode o app, navegue por algumas telas e mande-o para segundo
plano (isso envia na hora). Em até um minuto aparecem na tela
Instrumentação: `session_start`, `screen_view` das telas, a duração das
requisições e, 30 s depois do início, o `immunoops.sdk_handshake` com o que
está ligado e o que falta.

Para ver o que o SDK manda sem depender do console, aponte o
`IMMUNOOPS_ENDPOINT` para um servidor local que grave os POSTs (no
emulador Android, o Mac é `10.0.2.2`). Foi assim que o CRIA foi validado.

## Problemas conhecidos

| Sintoma | Causa | Solução |
| --- | --- | --- |
| `HTTP 401: tenant identification required` | Chave de outro ambiente | Endpoint do mesmo console da chave (passo 1) |
| `HTTP 500 ... clickhouse ... Cannot parse input ... key timestamp` | O backend grava a data num formato que o ClickHouse recusa (em staging, out/2026) | Correção no backend do Immuno Ops. O SDK trata 5xx como falha temporária: guarda na fila (até `maxQueueSize`) e reenvia |
| Build Android: `requires Android Gradle plugin 8.9.1 or higher` | `connectivity_plus` 7.1+ com AGP antigo | Passo 6, Android |
| Build iOS: `minimum platform version from 13.0 to at least 15.0` | Deployment target 13 com SPM | Passo 6, iOS |
| Telas chegam como `_CustomTransitionPageRoute` | SDK anterior a 0.2.1 com `pageBuilder:` | SDK 0.2.1+ |
| `memory_pressure` toda vez que o app sai da tela (Android) | SDK anterior a 0.2.1 | SDK 0.2.1+ |
| Emulador Android sem rede (`dns_error`) | DNS IPv6 do Mac, que o emulador não usa | `emulator -avd <nome> -dns-server 8.8.8.8` |
| Build web do app no Docker não acha o SDK | Dependência por `path:` | Trocar para `immunoops_flutter: ^0.2.2` (passo 2) |

## Atualizar

Suba o teto em `immunoops_flutter: ^x.y.z` e rode `flutter pub get`. Leia o
[CHANGELOG](../CHANGELOG.md) antes: enquanto for 0.x, subir o minor (0.2 →
0.3) pode mudar nomes de métricas e atributos. Correções ficam no patch.
Toda telemetria leva `telemetry.sdk.version`, então o console mostra qual
app está em qual versão.
