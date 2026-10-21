# ADR-003: privacidade e segurança

**Status:** aceito · 2026-10-19

## Decisão

- **Mascaramento no aparelho, antes do envio:** CPF, cartões (só
  sequências que começam como cartão e passam no Luhn), e-mails, tokens
  `Bearer`, query string e fragmento de URLs em texto livre, e qualquer
  valor sob chave sensível (`senha`, `token`, `cpf`, `cartao`, `secret`...).
  Mesmas regras do SDK Node, com duas diferenças deliberadas: fragmentos
  curtos de chave (`rg`, `pin`) só valem como palavra inteira, e números
  que não passam no Luhn ficam (timestamps, pedidos).
- **Nada identifica a pessoa:** sem nome, telefone, IP ou id do aparelho;
  `app.installation.id` e `session.id` são aleatórios.
- **Rede:** só tempo, código, método, host e rota como template
  (`/aulas/:id`). Nunca corpo, cabeçalhos ou query.
- **Consentimento:** `requireConsent: true` não coleta nada até
  `ImmunoOps.setConsent(true)`; retirar o consentimento apaga a fila.
- **Envio:** só `Authorization` e `Content-Type` (outro cabeçalho viraria
  preflight de CORS na web).
- **Nunca derrubar o app:** handlers de erro do app são preservados e
  sempre chamados; falhas internas viram diagnóstico; valores que não viram
  JSON são convertidos antes de entrar na fila.

## Riscos conhecidos e o que falta no backend

- A chave fica dentro do binário e pode ser extraída. Hoje ela é o token
  do agente, sem escopo nem expiração. O backend precisa de uma chave de
  cliente só de ingestão, revogável e com limite de volume.
- A rota de ingestão aceita o tenant pelo cabeçalho `X-Scope-OrgID` sem
  token válido. Precisa exigir token.
- A rota responde 405 ao preflight (OPTIONS): na web o navegador bloqueia o
  envio até isso ser corrigido.
