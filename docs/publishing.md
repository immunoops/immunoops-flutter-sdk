# Publicação e versões

## Hoje

O pacote vive no repositório `immunoops/immunoops-flutter-sdk`
(`publish_to: none`). Os apps dependem dele por git, presos a uma tag:

```yaml
dependencies:
  immunoops_flutter:
    git:
      url: https://github.com/immunoops/immunoops-flutter-sdk.git
      ref: v0.2.1
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
4. A tag dispara `.github/workflows/release.yml`: confere tag, pubspec,
   `version.dart` e CHANGELOG, roda análise e testes, e espera a aprovação
   do ambiente `release`. Aprovado, empacota o commit da tag e publica
   `immunoops_flutter-X.Y.Z.tar.gz` (com o `.sha256`) no Artifact Registry
   do projeto `immunoops-artifacts`, repositório `sdk`, pacote
   `immunoops-flutter`, e anexa os mesmos arquivos a um GitHub Release.
   Uma versão já publicada não é sobrescrita: o job falha.

O acesso ao Google Cloud é por Workload Identity Federation (sem chave): só
jobs do ambiente `release` deste repositório podem usar a conta de serviço
`ci-sdk-flutter` (infraestrutura: `immunoops-infrastructure`, módulo
`github-wif`).

### Ambiente `release` no GitHub

Settings › Environments › `release`: revisores obrigatórios e regra de
tags (`v*`) como as únicas permitidas a implantar. Sem esse ambiente, o
GCP recusa o job.

### Baixar uma versão publicada

```sh
gcloud artifacts generic download \
  --project=immunoops-artifacts --location=us-central1 --repository=sdk \
  --package=immunoops-flutter --version=X.Y.Z --destination=./sdk
```

Exige a role de leitura no repositório `sdk` (variável `sdk_reader_members`
no Terraform).

## Em aberto

Decidir entre pub.dev (se o SDK for aberto, Apache-2.0) e um repositório
pub privado. A troca muda só o bloco de dependência acima. O Artifact
Registry não tem formato Dart, por isso a release fica como pacote genérico
versionado, e os apps seguem por `git` + tag. Enquanto a `LICENSE` for
proprietária, publicar no pub.dev não é uma opção.
