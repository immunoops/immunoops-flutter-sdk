# Publicação e versões

## Hoje

O pacote vive no repositório `immunoops/immunoops-flutter-sdk`
(`publish_to: none`). Os apps dependem dele por git, presos a uma tag:

```yaml
dependencies:
  immunoops_flutter:
    git:
      url: https://github.com/immunoops/immunoops-flutter-sdk.git
      ref: v0.2.0
```

Durante o desenvolvimento, `path:` apontando para a pasta local.

## Versões

- SemVer: quebra de API pública ou de nome de atributo sobe o major
  (enquanto for 0.x, o minor).
- Cada versão tem entrada no `CHANGELOG.md` e uma tag
  `vX.Y.Z` no commit de merge. Tag publicada não se move
  nem se apaga: isso é o que torna a versão imutável para quem depende
  dela por `ref`.
- `lib/src/core/version.dart` acompanha o `pubspec.yaml` (há teste para
  isso), e a versão vai em `telemetry.sdk.version` em todo dado.

## Para fazer a release

1. `flutter analyze`, `flutter test` e o ponta a ponta em ao menos uma
   plataforma.
2. Atualizar `version` no `pubspec.yaml`, `version.dart` e o `CHANGELOG.md`.
3. Merge na `main`, tag `vX.Y.Z` no commit do merge.

## Em aberto

Decidir entre pub.dev (se o SDK for aberto, Apache-2.0) e um repositório
pub privado. A troca muda só o bloco de dependência acima.
