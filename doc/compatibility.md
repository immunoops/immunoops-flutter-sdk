# Compatibilidade

## Requisitos

| Item | Mínimo |
| --- | --- |
| Dart | 3.5 |
| Flutter | 3.24 |
| Android | minSdk 21 (exigência dos plugins `*_plus`) |
| iOS | o mínimo do app (não verificado abaixo do iOS 26) |
| Web | compila em JS e Wasm; modo reduzido |

## Testado em 2026-10-19

| Ambiente | Versão | O que rodou |
| --- | --- | --- |
| Flutter | 3.44.2 | análise, testes, ponta a ponta |
| Flutter | 3.35.3 | análise e testes |
| Flutter | 3.24.5 (mínimo declarado) | análise e testes |
| Emulador Android | Android 15 (API 35), Pixel 6a | ponta a ponta |
| Simulador iOS | iOS 26.5, iPhone 17 Pro (Xcode 26.6) | ponta a ponta |
| macOS | 26.7.1 | ponta a ponta |
| Web | build JS e Wasm | compilação, sem execução |
| App CRIA | `pubspec.lock` real | resolução de dependências sem conflito |

O ponta a ponta reproduz o incidente de checkout de `doc/simulation.md`
contra um servidor local que faz o papel da API de pagamento e da
ingestão.

## Por plataforma

| Captura | Android | iOS | macOS | Web |
| --- | --- | --- | --- | --- |
| Erros do Dart | sim | sim | sim | sim |
| Crash nativo, ANR, OOM | não (v2) | não (v2) | não | não |
| Telas, jank, jornadas | sim | sim | sim | sim |
| Abertura cold e warm | sim | sim | sim | sim |
| Rede, DNS e TLS separados | sim | sim | sim | só `connection_error` (o navegador esconde a causa) |
| Memória (`app.memory.rss_mb`) | sim | sim | sim | não |
| Pressão de memória | sim | sim | sim | não |
| Bateria | sim | só aparelho físico (o simulador não tem) | não verificado | não verificado |
| Conectividade | sim | sim | sim | sim |
| Fila em disco | sim | sim | sim | só memória |
