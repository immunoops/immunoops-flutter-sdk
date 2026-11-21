# Custo do SDK no app (IMOB-024)

`benchmark/overhead_test.dart` mede quanto cada chamada custa na thread de
UI, da API pública até a fila. Envio e disco rodam fora desse caminho.

```sh
flutter test benchmark/
```

Medido em 2026-10-19 com Flutter 3.44.2, `flutter test` (Dart VM em modo
JIT) num Mac. Em release (AOT) no aparelho os números tendem a ser menores;
num celular de entrada, maiores. Média de 20 000 chamadas:

| Chamada | Custo |
| --- | --- |
| `metric` | 3,0 µs |
| `event` (com mascaramento do payload) | 5,5 µs |
| `log` | 3,8 µs |
| `error` com stack trace | 229 µs |
| frame (callback de `FrameTiming`) | 0,17 µs |
| jornada (`start` + `end`) | 32 µs |

Um frame a 60 Hz tem 16 600 µs. O erro com stack é o mais caro, por formatar
e mascarar até 8 KB de stack; ele é raro e limitado a 5 por minuto por erro
igual.

## Ainda não medido

- Bateria, CPU e rede num aparelho real ao longo de uma sessão. Plano:
  Android Studio Profiler (Energy e Network) e Instruments (Energy Log) no
  app CRIA com e sem o SDK, 15 minutos de uso igual.
- Memória: a fila tem teto (`maxQueueSize`, 2000 itens por padrão); o pico
  real depende do tamanho dos itens e não foi medido.
