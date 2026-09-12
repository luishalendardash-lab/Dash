# App no celular e notificações

Duas coisas: instalar a dash como app e receber avisos da captação.

---

## O que subir

No frontend, além do `index.html`:

```
manifest.json
service-worker.js
icones/  (a pasta inteira)
```

Os três precisam estar na **raiz** do site, no mesmo nível do
`index.html`. O service worker só funciona assim — num subdiretório ele
não consegue controlar a página.

---

## Instalar no celular

Depois de subir, abra a dash no celular.

**Android** — aparece o botão *Instalar na tela de início* em Ajustes, ou
o próprio Chrome oferece.

**iPhone** — toque em **Compartilhar** e depois em **Adicionar à Tela de
Início**. O iOS não tem botão automático.

No iPhone as notificações **só funcionam depois de instalar**. Aberto no
Safari, sem instalar, ele não recebe nada — é limitação da Apple.

---

## Notificações

### 1. Gerar as chaves

As chaves identificam o remetente. Rode uma vez, num terminal com Node:

```js
const { webcrypto: c } = require('node:crypto');
(async () => {
  const par = await c.subtle.generateKey(
    { name: 'ECDSA', namedCurve: 'P-256' }, true, ['sign', 'verify']);
  const pub = await c.subtle.exportKey('raw', par.publicKey);
  const jwk = await c.subtle.exportKey('jwk', par.privateKey);
  const b = (x) => Buffer.from(x).toString('base64')
    .replace(/\+/g,'-').replace(/\//g,'_').replace(/=+$/,'');
  console.log('VAPID_PUBLIC_KEY  =', b(pub));
  console.log('VAPID_PRIVATE_KEY =', jwk.d);
})();
```

Se preferir, use as que já foram geradas:

```
VAPID_PUBLIC_KEY  = BC5I43ETCcuapkAWiaJ-7qg2hw-FEDuidZFGB39hxxeJfiOukLzBmulzXP2LanPI82yZnkRHqB_EvkyVQLYDGuc
VAPID_PRIVATE_KEY = zOWBoA2iK4nqjB4Ul9fE_lkds2050cgVIu1NPG9UB8A
```

### 2. Configurar no Worker

**Settings → Variables and Secrets**

| Nome | Tipo | Valor |
|---|---|---|
| `VAPID_PUBLIC_KEY` | Text | a chave pública |
| `VAPID_PRIVATE_KEY` | **Secret** | a chave privada |
| `VAPID_CONTATO` | Text | `mailto:seu@email.com` |

A privada tem que ser Secret. Com ela, qualquer um manda notificação em
nome do seu site.

### 3. Rodar o SQL

```
99i_push.sql
```

### 4. Ativar no aparelho

Em **Ajustes**, na seção *Avisos de captação*, toque em **Receber avisos
neste aparelho**. O navegador pede permissão; autorize.

Cada aparelho precisa ativar separadamente — celular e computador são
inscrições diferentes.

---

## Como os avisos funcionam

Um resumo da captação, de tempo em tempo:

```
Lançamento Setembro/26
59 leads · 28 engenheiros
18 no grupo (30,5%)
CPL eng R$ 16,37
faltam 1.441 para a meta
```

Você escolhe o intervalo (1 a 12 horas) e a faixa de horário. Por padrão
só envia durante lançamento em andamento — aviso fora de época treina a
pessoa a ignorar a notificação.

O botão **Enviar um agora** dispara na hora, ignorando intervalo e
horário, e mostra o texto que foi enviado.

---

## Se não chegar

**"Este navegador não recebe notificação"** — no iPhone, instale o app
primeiro. No computador, use Chrome, Edge ou Firefox.

**Autorizou e não chega** — confira se `VAPID_PRIVATE_KEY` está como
Secret e sem espaços. Depois use *Enviar um agora*: se der erro, a
mensagem aparece na tela.

**Chegou uma vez e parou** — o aparelho pode ter trocado a inscrição, o
que acontece ao limpar dados do navegador. Desative e ative de novo.

**Aparelho com erro na lista** — remova pelo ✕ e ative de novo. A dash
também remove sozinha quando o aparelho não existe mais.

---

## Sobre o cache

O app guarda a interface para abrir rápido, mas **nunca os dados** do
lançamento. Número de lead em cache é pior que número nenhum: você
olharia um valor velho pensando que é o de agora.

Por isso, sem internet o app abre e mostra as telas vazias, em vez de
mostrar dados de ontem.
