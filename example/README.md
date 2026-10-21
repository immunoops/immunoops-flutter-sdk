# Loja exemplo do immunoops_flutter

A loja do cenário de `docs/simulation.md`: uma home e um checkout com a
jornada `checkout.payment`. Cada botão "Pagar" reproduz um momento do
incidente INC-ANDROID-204 (sucesso, lentidão, timeout, 504, 500, crash), e
a home tem tela lenta, erro de build, erro assíncrono e pressão de memória.
O autodiagnóstico do SDK aparece na própria tela.

```sh
flutter create --platforms=android,ios,web .
flutter run --dart-define=IMMUNOOPS_CLIENT_KEY=<chave> \
  --dart-define=IMMUNOOPS_ENDPOINT=https://staging.immunoops.io/agent/ingest
```

A API de pagamento simulada é `https://httpbin.org` (troque com
`--dart-define=PAYMENT_API=...`). Os dados aparecem em Instrumentação →
*immunoops-flutter-example* no console.

O teste de ponta a ponta (`integration_test/`) não precisa de chave nem de
internet: sobe um servidor local que faz o papel da API de pagamento e da
ingestão. No Android, adicione `android:usesCleartextTraffic="true"` ao
`<application>` do manifesto para ele aceitar HTTP local.
