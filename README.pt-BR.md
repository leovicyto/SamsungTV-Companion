# SamsungTV-Companion

**Sua Smart TV Samsung liga e desliga junto com o PC (Windows).** Para quem usa uma TV Samsung (QLED,
Neo QLED, The Frame, Crystal UHD… qualquer modelo com Tizen) como monitor do computador ou para jogar no sofá.

[English](README.md)

Quem usa uma Smart TV Samsung como monitor do PC conhece o problema: placa de vídeo de PC não tem
HDMI-CEC, então a TV não acompanha o computador. Você desliga o Windows e a TV fica ligada mostrando
"Sem sinal"; liga o PC e precisa ir atrás do controle.

O SamsungTV-Companion resolve isso usando os recursos de rede da própria TV. É PowerShell, mais um
pequeno programa opcional em C# que é compilado no seu PC na hora da instalação: sem dependências e
sem executáveis prontos no repositório.

- **PC liga, faz login ou volta da suspensão** → TV liga (Wake-on-LAN, ~10 s)
- **PC desliga** → TV desliga
- **PC reinicia** → TV continua ligada (configurável)
- **TV desligada pelo controle, você mexe no mouse ou teclado** → TV liga de novo (opcional)
- **Roteador muda o IP da TV** → ela é reencontrada pelo endereço MAC
- **Leve**: ligar e desligar só rodam nesses momentos; o religar pelo mouse/teclado (opcional) usa
  cerca de 2 MB de RAM

É o equivalente para Samsung do que o [LGTV Companion](https://github.com/JPersson77/LGTVCompanion)
faz para TVs LG. Sem vínculo com a Samsung.

---

## Requisitos

**TV:** Smart TV Samsung com Tizen (2016 ou mais nova). Testado numa **QN55Q70T (2020)**.
[Conte aqui](../../issues) se funcionou ou não no seu modelo.

Configure uma vez na TV:

| Configuração | Valor | Por quê |
|---|---|---|
| Configurações › Geral › Rede › Configurações especialistas › **Ligar com dispositivo móvel** | Ativado | mantém a rede ativa em espera, pra o Wake-on-LAN conseguir ligar a TV |
| Configurações › Geral › Rede › Configurações especialistas › **IP Remote** (se existir) | Ativado | permite o controle remoto pela rede |
| Configurações › Geral › Gerenciador de dispositivos externos › Gerenciador de conexão de dispositivos › **Notificação de acesso** | Somente na primeira vez | a TV pede uma vez para autorizar o PC |

**Use cabo de rede na TV se puder.** No Wi-Fi funciona, mas nos testes às vezes um comando se perdia
(a TV ignorou um desligar uma vez e não acordou outra). No cabo todos os testes funcionaram, e a TV
acordou cerca de 2 s depois do primeiro pacote.

**PC:** Windows 10 ou 11 (testado no Windows 11 Pro), Windows PowerShell 5.1 (já vem no Windows),
permissão de administrador para instalar. PC e TV na mesma rede local.

## Instalação

1. [Baixe o ZIP](../../archive/refs/heads/main.zip) e extraia (ou use `git clone`).
2. O Windows marca arquivos baixados como inseguros. Desbloqueie uma vez: abra o PowerShell na pasta e
   rode `Get-ChildItem -Recurse | Unblock-File`.
3. **Ligue** a TV.
4. Dê dois cliques no **`Install.cmd`** e aceite o pedido de administrador.

O instalador:

1. procura TVs Samsung na rede (se houver mais de uma, você escolhe);
2. pareia: **escolha "Permitir" na TV** quando ela perguntar;
3. opcionalmente testa: **desliga e liga a TV sozinho** (cerca de 1 minuto);
4. pergunta se a TV deve continuar ligada quando o Windows reiniciar;
5. pergunta se a TV deve ligar de novo quando você mexer no mouse ou teclado depois de desligá-la pelo
   controle;
6. instala os gatilhos (veja [Como funciona](#como-funciona)).

Se a TV mudar do Wi-Fi para o cabo (ou o contrário), rode o instalador de novo: a TV ganha outro
endereço MAC.

Opções do instalador (num PowerShell como administrador): `src\Install.ps1 -TvAddress 192.168.1.50 -OnRestart Keep -WakeOnInput Yes -SkipPowerTest`

## Controle manual

Depois de instalado, os arquivos ficam em `C:\ProgramData\SamsungTV-Companion`:

```powershell
$tv = "$env:ProgramData\SamsungTV-Companion\SamsungTV.ps1"
powershell -File $tv On        # liga (Wake-on-LAN)
powershell -File $tv Off       # desliga
powershell -File $tv Status    # IP, estado e pareamento
powershell -File $tv Discover  # lista as TVs Samsung da rede
```

Funciona bem num atalho de teclado, num botão do Stream Deck ou num script do AutoHotkey.
Tudo fica registrado em `C:\ProgramData\SamsungTV-Companion\SamsungTV.log`.

## Como funciona

| Evento | Mecanismo |
|---|---|
| Ligar, login, voltar da suspensão | Tarefa agendada `SamsungTV-Companion - Power On` (roda como SYSTEM) manda pacotes Wake-on-LAN a cada 2 s até a TV dizer que ligou |
| Desligar | Um **script de desligamento da política de grupo local**. O Windows roda ele com a rede ainda ativa e espera terminar. Ele manda `KEY_POWER` pela API de controle remoto da TV (`wss://<tv>:8002`), só se a TV estiver ligada |
| Reiniciar | O mesmo script lê o tipo de desligamento que o Windows registra (evento 1074) e deixa a TV ligada |
| Mouse/teclado com a TV desligada (opcional) | O `SamsungTVWatcher.exe` roda na sua sessão (tarefa `SamsungTV-Companion - Wake on input`). Consulta a TV a cada 10 s e, se ela estiver desligada há pelo menos 15 s e houver uso do mouse ou teclado, manda o Wake-on-LAN. Usa cerca de 2 MB de RAM e praticamente nada de processador |

Detalhes técnicos, incluindo por que os caminhos óbvios não funcionam, em [docs/how-it-works.md](docs/how-it-works.md) (em inglês).

## Solução de problemas

Comece pelo `C:\ProgramData\SamsungTV-Companion\SamsungTV.log`.

**A TV não liga**
- Confira se **Ligar com dispositivo móvel** está ativado. Sem isso, a TV desliga a rede em espera.
- Use cabo de rede. No Wi-Fi às vezes um pacote se perde, e o roteador precisa repassar pacotes de
  broadcast para os aparelhos sem fio.
- Passou a TV do Wi-Fi para o cabo? Rode o instalador de novo: o cabo tem outro endereço MAC.

**O aviso "Permitir" não aparece / o pareamento falha**
- Deixe a **Notificação de acesso** em *Somente na primeira vez*.
- Em **Gerenciador de conexão de dispositivos › Lista de dispositivos**, apague ou permita o PC se ele estiver como negado.
- Reinicie a TV de verdade: segure o botão Power do controle até aparecer o logo da Samsung.

**A TV não desliga quando o PC desliga**
- Em PC de empresa (num domínio), as políticas do domínio podem sobrepor scripts de desligamento locais.
- O Windows Home ainda não foi testado.

**A TV liga sozinha logo depois que eu desligo pelo controle**
- É o religar pelo mouse/teclado vendo movimento. Ele espera 15 s depois que a TV apaga; aumente
  `wakeOnInputGraceSeconds` no `config.json` ou reinstale com `-WakeOnInput No`.
- O log dele fica em `%LOCALAPPDATA%\SamsungTV-Companion\watcher.log`.

**A TV desliga quando eu reinicio**
- O tipo de reinício é lido do log do Windows em vários idiomas. Se o seu não for reconhecido,
  [abra uma issue](../../issues) com o resultado de
  `Get-WinEvent -FilterHashtable @{LogName='System';Id=1074} -MaxEvents 3 | % { $_.Properties[4].Value }`.

## Desinstalar

Dois cliques no **`Uninstall.cmd`**, ou rode `C:\ProgramData\SamsungTV-Companion\Uninstall.ps1` como
administrador. Ele remove as tarefas agendadas, o religar pelo mouse/teclado, a própria entrada de script
de desligamento (outros scripts de desligamento não são tocados) e os arquivos instalados.

## Limitações e próximos passos

- [ ] Desligar a TV quando o PC **suspende** (por enquanto, use o *Desligamento automático / Sem sinal* da própria TV)
- [ ] Desligar a TV quando a tela apaga por inatividade
- [x] Ligar a TV pelo mouse/teclado depois de desligá-la pelo controle
- [ ] Mais de uma TV por PC
- [ ] Testar no Windows Home e em mais modelos de TV

## Segurança e privacidade

- Tudo fica na sua rede local: sem nuvem, sem conta Samsung, sem telemetria.
- Ligar e desligar rodam como SYSTEM, então a pasta de instalação só aceita alterações de Administradores
  e SYSTEM. O religar pelo mouse/teclado roda com as permissões normais do seu usuário.
- O token de pareamento fica no `config.json` dessa pasta.
- A TV usa um certificado autoassinado na porta 8002, então o certificado não é validado
  (só na conexão com a TV).

## Perguntas frequentes

**Por que minha TV Samsung não liga e desliga junto com o PC?**
As TVs acompanham os aparelhos pelo HDMI-CEC (Anynet+ na Samsung), mas placas de vídeo de PC (NVIDIA,
AMD, Intel) não têm CEC. Então a TV nunca fica sabendo que o PC desligou ou ligou. O SamsungTV-Companion
usa a rede no lugar disso.

**Preciso de adaptador USB-CEC, Raspberry Pi, Home Assistant ou SmartThings?**
Não. Ele conversa direto com a TV pela sua rede local: sem hardware extra, sem nuvem e sem conta Samsung.

**Quais TVs Samsung funcionam?**
Smart TVs com Tizen (2016 em diante) que tenham *Ligar com dispositivo móvel*. Testado numa QN55Q70T
(2020). Outros modelos devem funcionar. [Conte pra gente](../../issues) se funcionou ou não.

**É o LGTV Companion para Samsung?**
A ideia é essa: mesmo objetivo, para TVs Samsung. É um projeto separado, sem código em comum.

**A TV desliga quando o Windows reinicia (por exemplo, depois de uma atualização)?**
Não. Por padrão ela continua ligada no reinício e só desliga quando você desliga o PC.

**Dá pra controlar a TV por script, atalho de teclado ou Stream Deck?**
Sim, veja [Controle manual](#controle-manual).

## Créditos

- [LGTV Companion](https://github.com/JPersson77/LGTVCompanion): a inspiração, para TVs LG.
- [samsungtvws](https://github.com/xchwarze/samsung-tv-ws-api) e
  [samsungctl](https://github.com/kdschlosser/samsungctl): documentação do protocolo das TVs Samsung feita pela comunidade.

## Licença

[MIT](LICENSE)
