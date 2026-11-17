# SNES16

Emulador de **Super Nintendo** feito para um **iPad antigo com iOS 8**. Foi testado num iPad 3 (A5X, armv7) com iOS 8.4.1 e jailbreak.

É o irmão do [MD16](https://github.com/douugr/md16): o mesmo frontend libretro em Objective-C/UIKit, agora com o core [Snes9x 2005](https://github.com/libretro/snes9x2005) compilado junto no app. O Snes9x 2005 é uma versão antiga e leve do Snes9x, a que melhor cabe num processador de 2012.

## Funcionalidades

- Vídeo em OpenGL ES 2 (RGB565, até 512×512 nos modos de alta resolução)
- Áudio por RemoteIO, com o ritmo do jogo guiado pela fila de som
- Controle na tela no formato do controle do console: direcional, A/B/X/Y em losango, L/R nos cantos de cima e Select/Start embaixo
- **Controle Bluetooth** (testado com o 8BitDo Pro 2) pelo BTstack, com assistente que aprende os botões, direcional digital e analógico, e reconexão automática
- **Envio de ROMs pelo navegador:** a tela "Enviar ROMs" mostra um endereço (`http://<ip-do-ipad>:8080`); no computador é só arrastar os arquivos
- **Patch automático IPS/BPS** com o mesmo nome da ROM. Se a ROM tem os 512 bytes de cabeçalho de copiadora, o patch é aplicado na ROM sem cabeçalho, que é o caso mais comum
- Estados salvos em 3 slots manuais, salvamento automático ao sair e "Continuar de onde parou?"
- SRAM (saves internos do cartucho) gravada automaticamente
- Run-ahead de 1 quadro (opcional, desligado por padrão: o core de SNES é mais pesado)
- Medidor de desempenho opcional
- Visual inspirado no console e nos cartuchos da época: cinza claro com frisos, roxo e lilás. A biblioteca mostra os jogos como cartuchos com etiqueta. O ícone é original

## Requisitos

- iPad com iOS 8 e jailbreak, com **OpenSSH** e **BTstack** (pacote Cydia `ch.ringwald.btstack` 1.1)
- Mac com o **Xcode 13.4.1** extraído (só o toolchain é usado) e `ldid`
- Acesso SSH ao iPad como root, de preferência com chave

O app é instalado em `/Applications`, fora do sandbox, para poder falar com o BTdaemon.

## Compilar e instalar

```bash
export X13=/caminho/para/Xcode-13.4.1.app/Contents/Developer   # padrão: ../Xcode-13.4.1.app
export IPAD=192.168.x.x

./build.sh            # compila build/SNES16.app
./build.sh install    # compila e instala no iPad via SSH
./build.sh roms       # envia as ROMs de ../roms para o iPad
```

Na primeira vez, o `build.sh` baixa o Snes9x 2005 num commit fixo e compila o core.

## Uso

- As ROMs (`.sfc`, `.smc`, `.swc`, `.fig`) ficam em `Documents/SNES16/roms`. Mande pela tela **Enviar ROMs**. Você precisa ter as suas próprias: nenhuma ROM acompanha este projeto.
- **Controle:** deixe o Bluetooth do iOS desligado e o Wi-Fi ligado (no iPad 3 eles dividem o chip). Depois vá em Controle → Procurar controles → toque no controle → Configurar botões.

## Licenças

- O código deste repositório é do autor. O ícone é original, feito para o projeto.
- O **Snes9x 2005** não é incluído aqui: ele é baixado na hora de compilar e segue a licença do Snes9x, de uso **não comercial**.
- Os headers em `vendor/btstack` são do BTstack (© BlueKitchen GmbH / Matthias Ringwald) e seguem a licença do BTstack.
