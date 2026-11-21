# ADR-001: um pacote Flutter, com módulos internos

**Status:** aceito · 2026-10-19

## Contexto

O planejamento original previa um SDK Android em Kotlin, multi-módulo
(Gradle, AAR no Artifact Registry). Os apps que vão usar o SDK primeiro,
a começar pelo CRIA, são Flutter e rodam em Android, iOS e web. As
próprias referências recomendam começar com um artefato só e dividir
quando houver uma necessidade concreta.

## Decisão

Um pacote Dart/Flutter, `immunoops_flutter`, no repositório
`immunoops/immunoops-flutter-sdk`, com os módulos do planejamento como pastas:

| Módulo planejado | Pasta | Conteúdo |
| --- | --- | --- |
| sdk-core | `lib/src/core/` | API pública, configuração, cliente, contexto, sessões (`lifecycle/`), privacidade |
| sdk-crash | `lib/src/crash/` | `CrashReporter`, fingerprint |
| sdk-anr | — | v2, código nativo (ver abaixo) |
| sdk-network | `lib/src/network/` | Interceptor Dio, wrapper `http`, classificação de erro, conectividade |
| sdk-performance | `lib/src/performance/` | Abertura, frames, memória, bateria |
| sdk-rum | `lib/src/rum/` | Telas e jornadas |
| sdk-exporter-otlp | `lib/src/exporter/` | Buffer, retry, envio, fila em disco |

Os módulos são internos (`lib/src/`); o app importa só
`package:immunoops_flutter/immunoops_flutter.dart`.

## O que fica para a v2

ANR, crash nativo, OutOfMemory e o tempo de abertura antes do Dart exigem
código nativo. Eles entram como plugin federado dentro deste mesmo pacote
(Kotlin no Android, Swift no iOS), que é onde o desenho Kotlin original
volta a valer.

## Consequências

- Uma dependência no app, um número de versão, uma documentação.
- Dividir em pacotes depois (`immunoops_flutter_native`, por exemplo) não
  muda a API pública.
- O pacote depende de `dio`, `http` e dos plugins `*_plus`; o `doctor`
  detecta conflito de versão com o app antes do build.
