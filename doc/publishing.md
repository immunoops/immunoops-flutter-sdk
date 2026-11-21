# Publicação e versões

## Onde o app pega o SDK

O pacote `immunoops_flutter` é publicado no pub.dev, no publisher
[immunoops.io](https://pub.dev/publishers/immunoops.io). O app depende
dele por versão:

```yaml
dependencies:
  immunoops_flutter: ^0.2.2
```

Página do pacote:
[pub.dev/packages/immunoops_flutter](https://pub.dev/packages/immunoops_flutter).

Durante o desenvolvimento, `path:` apontando para a pasta local.

## Versões

- SemVer: quebra de API pública ou de nome de atributo sobe o major
  (enquanto for 0.x, o minor).
- Cada versão tem entrada no `CHANGELOG.md` e uma tag
  `vX.Y.Z` no commit de merge. Tag publicada não se move
  nem se apaga.
- `lib/src/core/version.dart` acompanha o `pubspec.yaml` (há teste para
  isso), e a versão vai em `telemetry.sdk.version` em todo dado.
- A versão no pub.dev é imutável: publicar de novo o mesmo número falha.

## Para fazer a release

1. `flutter analyze`, `flutter test` e o ponta a ponta em ao menos uma
   plataforma. O CI também roda `dart pub publish --dry-run` no Flutter
   estável.
2. Atualizar `version` no `pubspec.yaml`, `version.dart` e o `CHANGELOG.md`.
3. Merge na `main`, tag `vX.Y.Z` no commit do merge.
4. A tag dispara dois workflows:
   - `.github/workflows/publish.yml` publica no pub.dev.
   - `.github/workflows/release.yml` empacota o mesmo commit no Artifact
     Registry e abre o GitHub Release.

Os dois esperam a aprovação do ambiente `release`. Uma versão já
publicada não é sobrescrita.

### pub.dev

O job usa o workflow oficial `dart-lang/setup-dart` (OIDC). Não há token
de publicação no GitHub. O pub.dev só aceita o job se a tag for `vX.Y.Z`
e o `version` do `pubspec.yaml` for `X.Y.Z`.

Isso vale a partir da segunda versão. O pub.dev não cria pacote por
GitHub Actions. A primeira versão é publicada pela conta pessoal de quem
está logado no `dart pub login`. O publisher entra depois, por
transferência.

1. No checkout que já tem `publish_to` ausente (o padrão é o pub.dev) e
   `version: 0.2.1`:

   ```sh
   dart pub publish
   ```

   Se o comando perguntar o destino, publique na sua conta, não em
   `immunoops.io`. A tag `v0.2.1` já existe num commit anterior, com
   `publish_to: none`; não vale reapontar essa tag. O `dart pub publish`
   manual usa o código deste checkout.

2. Em [pub.dev/packages/immunoops_flutter/admin](https://pub.dev/packages/immunoops_flutter/admin),
   transfira o pacote para o publisher `immunoops.io` (Transfer to
   publisher). Quem transfere precisa ser membro do publisher. A
   administração do publisher fica em
   [pub.dev/publishers/immunoops.io/admin](https://pub.dev/publishers/immunoops.io/admin).

3. No mesmo admin do pacote, já sob o publisher, Automated publishing,
   Enable publishing from GitHub Actions:

   | Campo | Valor |
   | --- | --- |
   | Repository | `immunoops/immunoops-flutter-sdk` |
   | Tag pattern | `v{{version}}` |
   | GitHub Actions environment | `release` |

   O ambiente `release` já existe neste repositório (revisores
   obrigatórios, só tags `v*`). Sem o mesmo nome no admin do pacote, o
   job autentica e o pub.dev recusa.

### Artifact Registry

O `release.yml` continua publicando o tarball
`immunoops_flutter-X.Y.Z.tar.gz` (com o `.sha256`) no projeto
`immunoops-artifacts`, repositório `sdk`, pacote `immunoops-flutter`, e
anexa os mesmos arquivos ao GitHub Release. O acesso ao Google Cloud é
por Workload Identity Federation (sem chave): só jobs do ambiente
`release` deste repositório podem usar a conta `ci-sdk-flutter`
(infraestrutura: `immunoops-infrastructure`, módulo `github-wif`).

```sh
gcloud artifacts generic download \
  --project=immunoops-artifacts --location=us-central1 --repository=sdk \
  --package=immunoops-flutter --version=X.Y.Z --destination=./sdk
```

Exige a role de leitura no repositório `sdk` (variável `sdk_reader_members`
no Terraform). Os apps não usam esse tarball: usam o pub.dev.
