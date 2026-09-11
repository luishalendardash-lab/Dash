# O formulário demora a aparecer no celular

Quase sempre é o **cache atrasando o script**, não o código. Plugins de
otimização seguram os scripts até a primeira interação do visitante — e o
scroll é justamente a interação que libera.

O resultado é o pior possível: quem abre a página e não rola embora sem
nunca ver o formulário.

---

## O código já vem preparado

O que a dash gera inclui os atributos que pedem aos otimizadores para não
atrasar:

```html
<div id="pd-captura"></div>
<script src="https://dash.luishalendardash.workers.dev/embed.js?l=..."
        data-no-optimize="1" data-no-defer="1" data-nowprocket
        data-cfasync="false"></script>
```

Se você colou o código antigo, copie de novo em **Quiz → Código para a
landing page**.

---

## Se continuar atrasando

### WP Rocket

**Configurações → Otimizar entrega de arquivos JavaScript**

Em *Atrasar execução de JavaScript*, adicione na lista de exclusões:

```
embed.js
workers.dev
```

Em *Carregar JavaScript de forma adiada*, adicione as mesmas linhas em
*Arquivos excluídos*.

### LiteSpeed Cache

**Page Optimization → JS Settings → JS Excludes**

```
embed.js
```

### Cloudflare

Se o Rocket Loader estiver ligado em **Speed → Optimization**, o atributo
`data-cfasync="false"` já resolve. Se não resolver, desligue o Rocket
Loader — ele costuma causar mais problema que ganho.

### Elementor

Em **Configurações → Recursos**, se *Otimizar carregamento de CSS* ou
*Melhorias de carregamento* estiverem ativos, teste desligando um por vez.

---

## Como confirmar que era o cache

Abra a página numa aba anônima **com o cache do plugin desativado** (a
maioria tem um botão "limpar cache" na barra do WordPress).

Se o formulário aparecer na hora, era o cache. Se continuar atrasando,
me avise — aí é outra coisa.

---

## Um teste que isola o problema

Abra direto o endereço do script no navegador:

```
https://dash.luishalendardash.workers.dev/embed.js?l=SEU-LANCAMENTO
```

Deve mostrar o código JavaScript na hora. Se demorar aqui, o problema é
de rede, não de plugin — mas isso é raro.
