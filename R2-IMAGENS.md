# Ligar o R2 para as imagens do e-mail

O bucket pode estar em **qualquer conta Cloudflare** — inclusive uma
diferente da que hospeda o Worker. A conexão é feita por credencial, não
por associação direta.

---

## 1. Criar o bucket

Na conta onde você tem o R2: **R2 → Create bucket**

Nome: `dash-imagens`

---

## 2. Deixar o bucket público

Sem isto o upload funciona mas ninguém vê a imagem — inclusive quem
receber o e-mail.

Abra o bucket → **Settings** → **Public access**

**Domínio próprio** (recomendado)
Em *Custom Domains*, adicione algo como `img.seudominio.com.br`.
Endereço próprio passa melhor nos filtros de spam que um domínio genérico.

**Domínio do R2** (mais rápido)
Em *R2.dev subdomain* → *Allow Access*.
Gera um endereço tipo `https://pub-a1b2c3d4.r2.dev`.

Copie o endereço.

---

## 3. Criar o token de acesso

**R2 → Manage R2 API Tokens → Create API Token**

| Campo | Valor |
|---|---|
| Permissions | **Object Read & Write** |
| Specify bucket | apenas `dash-imagens` |

Limitar a um bucket é importante: se a credencial vazar, o estrago fica
restrito às imagens de e-mail.

Ao criar, ele mostra uma vez só:

- **Access Key ID**
- **Secret Access Key**

Copie os dois agora — o segredo não aparece de novo.

Anote também o **Account ID**, que fica na página inicial do R2 (ou na
URL do painel).

---

## 4. Configurar no Worker

**Workers → dash → Settings → Variables and Secrets**

Tipo **Secret**:

| Nome | Valor |
|---|---|
| `R2_ACCESS_KEY_ID` | o Access Key ID do passo 3 |
| `R2_SECRET_ACCESS_KEY` | o Secret Access Key do passo 3 |

Tipo **Text**:

| Nome | Valor |
|---|---|
| `R2_ACCOUNT_ID` | o Account ID da conta do R2 |
| `R2_BUCKET` | `dash-imagens` |
| `R2_PUBLICO` | o endereço do passo 2, sem barra no final |

---

## Conferir

No gerador de e-mail, adicione um bloco de imagem e arraste um arquivo.

**Funcionou** — a imagem aparece na prévia.

**"faltam variaveis no Worker"** — a mensagem diz quais.

**"SignatureDoesNotMatch"** — o Access Key ID ou o Secret estão trocados,
ou um deles ficou com espaço no começo ou no fim ao colar.

**403** — o token não tem permissão de escrita, ou foi limitado a outro
bucket.

---

## Sobre as imagens

**Suba com o dobro da largura.** O e-mail exibe em 600px, mas telas retina
mostram borrado se o arquivo tiver exatamente 600. Use 1200.

**Abaixo de 200 KB.** O limite do upload é 5 MB, mas imagem pesada demora a
carregar e alguns clientes cortam o e-mail no meio.

**Sempre preencha a descrição.** Boa parte dos clientes bloqueia imagens até
o leitor liberar — a descrição é o que aparece nesse intervalo. Nunca deixe
informação essencial só dentro da imagem.

---

## Custo

O R2 não cobra pela saída de dados, que é onde os outros serviços pesam.
Dez mil imagens de e-mail por mês ficam na faixa gratuita com folga.
