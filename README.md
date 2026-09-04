# pp-banco

Banco **Prepacoin** — contas, IBAN PT50, transferências em P$ (Prepara Portugal)

**Status:** backend e frontend construídos e testados de ponta a ponta com
sessões reais (abertura de conta, emissão de fundo, transferência,
limite→aprovação, incumprimento, extrato, comprovante público).
**Depende de:** [pp-base](https://github.com/projetoempresaficticia/pp-base),
[classcard](https://github.com/projetoempresaficticia/classcard) (pp-identidade)

Site: https://projetoempresaficticia.github.io/pp-banco/

Documentação completa (PRDs e decisões) em
[prepara-portugal-docs](https://github.com/projetoempresaficticia/prepara-portugal-docs).

## Identidade visual (já fixada na skill)

- Nome do produto: **Prepacoin**
- Roxo (marca) `#8F41DE` · Laranja `#FF7535` · Roxo claro `#DAC0F4` ·
  Pêssego claro `#FFD6C2` · Branco `#FFFFFF` · Grafite `#2C2C2C`
- Cartão do dashboard em **gradiente roxo→laranja**; propositalmente
  distinta do azul institucional do ClassCard.

## O estado em que a base foi encontrada

As tabelas `contas` e `transacoes` já existiam (vazias, com o trigger de
auditoria da pp-base ligado), e três funções também: `banco_abrir_conta`,
`banco_transferir`, `fn_gerar_iban`. O diagnóstico encontrou sete problemas
— o primeiro grave:

1. **`banco_transferir` não verificava quem chamava.** Recebia o IBAN de
   origem por parâmetro e nunca conferia se a conta era de quem estava
   logado. Sendo `SECURITY DEFINER` chamável por `authenticated`, qualquer
   aluno logado esvaziava a conta de qualquer empresa. (A própria skill
   já pedia "valida que quem chama é dono/ADM da conta de origem" — a
   implementação é que não fazia.)
2. **RLS ligado com zero policies** nas duas tabelas — o frontend não
   conseguiria ler saldo nem extrato.
3. **Falência por qualquer tentativa sem saldo** — um erro de digitação
   do aluno já marcava a empresa como `falida` (estado terminal).
4. **Pendentes não reservavam saldo** — dava para empilhar transferências
   pendentes que somadas passavam do saldo.
5. **Sem `exception when others`** — erro cru vazava para o browser,
   contra a regra da pp-base.
6. **IBAN frágil** — `hashtext` é int4 (~2 mil milhões de valores), sem
   verificação de colisão; colidir estouraria a unique constraint.
7. **Não existia aprovar/rejeitar** — o fluxo limite→aprovação estava
   pela metade.

## O que este repositório fornece

- `sql/0001_rls_e_correcoes.sql` — policies de RLS (cada um vê a sua conta
  e a da sua empresa; professor vê tudo), reescrita de `banco_transferir`
  com a identidade vinda de `auth.uid()`, saldo disponível descontando
  pendentes, `banco_abrir_conta` restrito, `fn_gerar_iban` com garantia de
  unicidade, `banco_decidir_pendente` e `banco_verificar_comprovante`.
  Os helpers `fn_minha_cedula()`/`fn_minha_empresa_cedula()`/`fn_iban_meu()`
  são `SECURITY DEFINER` de propósito — é o padrão que evita a recursão de
  RLS que mordeu o classcard e o subsight.
- `sql/0002_saldo_extrato_aprovacao.sql` — `banco_saldo`, `banco_extrato`,
  `banco_aprovar`/`banco_rejeitar` (os nomes da skill, como invólucros
  finos sobre a lógica única do 0001) e `banco_creditar_inicial`.
  Sobre esta última: a skill diz que o fundo inicial "entra por
  transferência do fundo de investimento", e quem o injeta é o
  `pp-criar-empresa` — que é a app #10 e ainda não existe. Sem isto não
  havia forma de dinheiro entrar no sistema, nem para testar. Fica
  restrita ao professor, e regista a entrada como transação de categoria
  `emissao` (origem nula) para o dinheiro nunca aparecer sem rasto.
- `sql/0003_fix_null_nas_checagens.sql` — corrige um bug encontrado a
  testar o 0001/0002 **com sessão real**, descrito abaixo.

## O bug de NULL (vale para as próximas skills)

O professor não tem `empresa_id`, logo `fn_minha_empresa_cedula()` devolve
NULL. Em SQL, `'EP-2026-00002' not in ('PP-2026-00002', null)` não é
`true` — é `null` — e `if null then … end if` não entra. Resultado: a
checagem "esta conta é sua?" era **silenciosamente saltada** para quem não
tem empresa, exatamente o furo que o 0001 dizia estar a fechar.

O teste só não moveu dinheiro porque a conta alvo estava a zero, e o erro
devolvido foi "saldo insuficiente" em vez de "esta conta não é sua" — foi
essa mensagem errada que denunciou o problema. Depois de dar saldo à conta
para o teste ser honesto, a transferência indevida passou a ser recusada
pela razão certa.

**Regra:** nunca comparar com `in (…)` ou `<>` quando um dos lados pode ser
NULL — usar `is distinct from`, que devolve sempre true/false. O mesmo
padrão estava em cinco funções (`banco_transferir`, `banco_abrir_conta`,
`banco_saldo`, `banco_extrato`, `banco_decidir_pendente`), todas
corrigidas via o helper `fn_cedula_minha()`. As policies de RLS não
precisaram de correção: dentro de `using (…)`, NULL já é tratado como
"não permitido".

## A conta nasce com a cédula

`sql/0004_conta_automatica.sql` — decisão do Germano (2026-09-02): cada
pessoa e cada empresa já nasce com conta. `id_registar_pessoa` e
`id_registar_empresa` passam a criar a conta no mesmo passo do registo, e
devolvem o `iban` na resposta.

- **Empresa (`EP-…`)** → limite de aprovação de **100 000 cêntimos
  (P$ 1 000,00)**: acima disso a transferência fica pendente até um
  gerente aprovar.
- **Pessoa (`PP-…`)** → **sem limite**. Não pode ter: quem decide uma
  pendente é um gerente *da empresa dona da conta*, e uma conta pessoal
  não tem gerente — uma pendente ali ficaria presa para sempre.

Duas notas de desenho:

- **`banco_criar_conta_interna`** existe porque `banco_abrir_conta` valida
  quem está a chamar, e no momento do registo essa validação não serve
  (a pessoa criada ainda não tem sessão, e a cédula ainda não é de
  ninguém). A interna não valida chamador e está revogada de `PUBLIC` —
  só corre de dentro de outra função `SECURITY DEFINER`.
  `banco_abrir_conta` continua a ser a porta pública, que valida e delega.
- **Falhar a abrir conta não parte o registo.** A identidade é mais
  fundamental que a conta: a chamada vai num sub-bloco
  `begin … exception … end` (em plpgsql isso é uma subtransação), por
  isso um erro no banco desfaz só essa parte e a pessoa fica registada na
  mesma — com `aviso_banco` na resposta a dizer o que falhou.

## Faturas e boletos

`sql/0005_faturas_e_boletos.sql` — decisão do Germano (2026-09-04).

**O problema que resolve.** Pagar uma taxa a um órgão era: descobrir o
IBAN do órgão, transferir o valor certo ao cêntimo, copiar o **UUID** da
transação e colá-lo no formulário. Funciona, mas com ~1000 formandos é um
gerador de erros — e não ensina nada, porque na vida real ninguém copia
identificadores internos entre sites.

**O modelo.** Duas coisas ligadas, para **qualquer entidade cobrar de
qualquer outra** — órgão a empresa, empresa a empresa:

| | O que é |
|---|---|
| **Fatura** `FT-2026-000001` | diz o quê e quanto: linhas, valor, quem emitiu, quem deve |
| **Boleto** `BOL-2026-000001` | a ordem de pagamento gerada a partir dela: referência, valor, prazo |

Vive no Prepacoin porque é o banco que recebe pagamentos. Os outros apps
emitem por aqui e só perguntam se já foi pago.

**RPCs:** `banco_emitir_fatura` (em nome da minha empresa),
`banco_emitir_fatura_interna` (para os órgãos, que não têm funcionários —
revogada de `PUBLIC`), `banco_pagar_boleto`, `banco_boletos_por_pagar`,
`banco_verificar_fatura` (pública).

**O que ganhou de graça:** `banco_pagar_boleto` reaproveita
`banco_transferir`, logo herda o dono da conta, o saldo disponível a
descontar pendentes, e o **limite de aprovação**. Um boleto acima de
P$ 1 000 fica `em_pagamento` até um gerente aprovar — que é o
comportamento certo para uma despesa grande. `banco_decidir_pendente`
passou a fechar o boleto e liquidar a fatura quando aprova (e a devolvê-lo
a `por_pagar` quando rejeita); sem isso ficaria eternamente pendurado.

**A tabela `faturas` que já existia** (vazia, de uma sessão antiga) era só
para as utilities e **não tinha quem emite** — não representava "a Padaria
faturou ao Restaurante". Foi reconstruída, mantendo `servico` e `ciclo`
para o pp-utilities os usar depois.

Testado com sessões reais, incluindo o caso empresa→empresa que é a regra
de ouro do projeto: o Moinho faturou farinha à Padaria (4×P$ 25 +
P$ 10 de transporte = P$ 110, somado pelo servidor), a Padaria viu o
boleto no ecrã "por pagar" — sem IBAN nem UUID — e pagou num clique.
Mais: pagar duas vezes é recusado, pagar boleto de outra entidade é
recusado, um boleto de P$ 1 500 ficou à espera de aprovação e fechou
sozinho quando o gerente aprovou, e a fatura é verificável publicamente
com as linhas discriminadas.

## A referência multibanco, vinda do projeto original

`sql/0006_referencia_multibanco.sql` — decisão do Germano (2026-09-04):
trazer para cá o que o Prepacoin em Google Apps Script já fazia.

No original pagava-se um boleto escrevendo **entidade + referência**, como
num homebanking a sério. É melhor do que colar um `BOL-2026-000001`: são
dígitos que se leem em voz alta, se escrevem à mão, e que o sistema
consegue **conferir sozinho** antes sequer de ir à base de dados.

- **Entidade** (5 dígitos) — derivada da cédula do emitente por
  `fn_entidade_de`: `EP-2026-00009` → `20009`. Cada empresa tem sempre a
  mesma, como uma entidade real.
- **Referência** (9 dígitos) — 8 aleatórios + **dígito de controlo** de
  Luhn (`fn_digito_controlo`). Trocar dois dígitos ao escrever dá
  "Referência inválida — confira os dígitos" **sem** consultar nada: é o
  próprio número que se denuncia.

`banco_consultar_boleto` mostra o que se vai pagar antes de confirmar —
emitente, descrição, linhas e total — e recusa o que já foi pago (dizendo
a data), o cancelado e o que está em nome de outra entidade.
`banco_pagar_referencia` paga; `banco_cancelar_boleto` deixa o emitente
retirá-lo de circulação.

A coluna `referencia` já guardava o `BOL-…`, por isso os dígitos vivem em
**`referencia_mb`** — os dois identificadores coexistem.

## O documento imprimível

`documento.html` — o boleto e o comprovativo numa folha A4 desenhada em
CSS. O PDF sai pelo **"Imprimir → Guardar como PDF"** do próprio browser:
não carrega biblioteca nenhuma, e o que se vê no ecrã é exatamente o que
sai no papel. (No original o PDF era gerado no Google Drive; aqui não há
Drive.) O código de barras é decorativo e o rodapé diz isso ao leitor — o
pagamento faz-se escrevendo a entidade e a referência.

`sql/0007_boleto_documento.sql` deu-lhe uma porta própria,
`banco_boleto_documento`, porque `banco_consultar_boleto` é do **lado de
quem paga**: recusa boletos que não estejam em nome do consulente e
recusa os já pagos. Certo para o ecrã de pagamento, errado para o papel —
quem emitiu tem de poder reimprimir, e um boleto pago também. Sem essa
porta o documento caía numa lista com outra forma de dados e imprimia a
cédula do devedor debaixo do rótulo "Emitente", porque *contraparte*
significa coisas opostas conforme quem olha. Agora devolve sempre os dois
lados: **Emitente** e **A cargo de**, com nome e cédula.

## Bugs encontrados a testar a emissão pela UI

Três, todos do mesmo tipo: só aparecem com sessão real.

1. **A caixa "A quem vai faturar" estava sempre vazia.** Montava-se com
   `sb.from('empresas').select()`, e a RLS — bem — só devolve a ficha
   própria. Ninguém conseguia faturar a ninguém. A correção não é abrir a
   RLS: é o **`id_diretorio`** da pp-base, que devolve só o que é público
   (cédula, nome, tipo, setor, região, se tem conta). No mundo real esse
   registo é público — é o que a certidão permanente do Cartório atesta.
2. **Cédulas cruas nas listas** (`sql/0009_nomes_nas_listas.sql`) — as
   listas resolviam o nome com `left join public.empresas`, e uma pessoa
   que emite ou recebe faturas caía no `coalesce` para a cédula.
   `fn_nome_de` procura nas duas tabelas.
3. **"Saldo insuficiente (disponível: 0 cêntimos)"**
   (`sql/0008_moeda_e_erro_limpo.sql`) — o valor está certo, mas uma
   mensagem de erro é ecrã, e no ecrã o dinheiro escreve-se em P$.
   `fn_moeda` formata à saída; guardar e calcular continua em cêntimos.

O 0008 também tapou a fuga de `sqlerrm` no `banco_transferir`. **Atenção:
a mesma fuga existe em mais ~25 funções deste ecossistema** (todos os
repos): devolvem `'Falha ao …: ' || sqlerrm`, o que põe nomes de colunas
e de constraints no ecrã de um formando e viola o R1 da pp-base. Está por
limpar.

> Ao mexer no `banco_transferir` quase se criou uma **segunda sobrecarga**
> em vez de o substituir: a versão viva tem `p_categoria text` **sem**
> default. `create or replace` só substitui com a assinatura exata — vale
> sempre a pena ler o `pg_get_functiondef` antes, e não confiar no que o
> ficheiro de migração diz.

## Regras de negócio

- **Dinheiro em cêntimos de P$ (`bigint`)**, nunca vírgula flutuante.
- **Saldo disponível = saldo − pendentes de saída.** Uma transferência
  acima do `limite_aprovacao` fica `pendente` e já conta contra o
  disponível, para não se poder empilhar pendentes acima do saldo.
- **Aprovação:** só um `gerente` vinculado à empresa dona da conta de
  origem aprova/rejeita, e o saldo é revalidado no momento da aprovação.
- **Incumprimento:** decisão do Germano (2026-09-02) — só transferências
  recusadas de **obrigações** (`salario`, `imposto`, `renda`, `utilities`)
  marcam a empresa em `incumprimento`. Uma venda ou transferência avulsa
  sem saldo é apenas recusada e fica no extrato como `rejeitada`, para um
  erro de digitação não falir a empresa.
- Toda tentativa recusada fica registada — o extrato mostra o rasto.

## Testes

Testado com **sessões reais no browser** (não como service role, que
ignora a RLS e esconde exatamente esta classe de bug): abertura de conta e
idempotência, emissão de fundo pelo professor, transferência legítima,
**tentativa de transferir de conta alheia com saldo disponível → recusada**,
transferência abaixo do limite (conclui), acima do limite (fica pendente),
saldo disponível a descontar a pendente (250 000 de saldo com 210 000
pendentes recusou 100 000, oferecendo 40 000), aprovação pelo gerente,
venda sem saldo (recusa **sem** falir), salário sem saldo (recusa **e**
marca incumprimento), extrato com o rasto das rejeitadas, e comprovante
público sem login a devolver só os últimos 4 dígitos dos IBANs.

O frontend foi testado depois, também com login real: abrir conta pela UI
(pessoal e da empresa), cartão a mostrar saldo/IBAN, seletor entre as duas
contas, transferência de P$ 1250,50 que caiu em pendente por passar o
limite de P$ 1000,00, aprovação pela fila, e o extrato a fechar a
matemática (P$ 4000,00 de emissão − P$ 1250,50 = P$ 2749,50). O
comprovante foi verificado **com a sessão terminada**, provando que a
página pública funciona sem login.

Dados de teste do banco (contas e transações) limpos no fim. Ficaram na
Carteirinha uma empresa e uma pessoa de teste (`EP-2026-00002` "Padaria
Teste Prepacoin" e `PP-2026-00005` "Gerente Teste") — úteis como fixture,
mas é só dizer que se apagam.

## Frontend

- `index.html`/`app.js` — cartão da conta em **gradiente roxo→laranja**
  (saldo disponível, IBAN, e quanto está preso em pendentes), movimentos
  com badge de estado e código do comprovante, e um seletor entre a conta
  pessoal e a da empresa para quem tem as duas. Quem ainda não tem conta
  vê um painel para a abrir. Saldo em tempo real via Supabase Realtime.
- `transferir.html`/`transferir.js` — escolher de qual conta sai (mostrando
  disponível, preso em pendentes e o limite de aprovação), IBAN de destino,
  valor em P$ e categoria. O valor é convertido para cêntimos no cliente;
  o servidor volta a validar tudo.
- `aprovacoes.html`/`aprovacoes.js` — fila das transferências pendentes com
  aprovar/rejeitar.
- `comprovante.html`/`comprovante.js` — verificação pública, sem login,
  por código de autenticação (aceita `?codigo=…` na URL).
- `emitir.html`/`emitir.js` — fatura com linhas (descrição, quantidade,
  preço), total somado ao vivo só para o utilizador ver — quem manda é o
  servidor, que volta a somar a partir das linhas. Emite fatura + boleto
  num passo e mostra logo a entidade e a referência.
- `boletos.html`/`boletos.js` — pagar escrevendo **entidade + referência**,
  com painel de confirmação antes de tirar o dinheiro; abas "A pagar" e
  "Emitidos por mim", e cancelar para quem emitiu.
- `documento.html`/`documento.js` — a folha A4 do boleto e do
  comprovativo, para imprimir ou guardar em PDF.
- `web/estilos.css` + `web/comum-banco.js` — paleta e utilitários
  (formatação de P$, IBAN e datas). O cliente Supabase vem do `comum.js`
  da pp-base, carregado cross-repo.
- Ícones reaproveitados do cache local da skill `figma-icons` — nenhuma
  chamada nova ao Figma (a cota do plano Starter é mensal).

## Cache dos ficheiros locais

Cada `<script>`/`<link>` local leva `?v=<sha1 dos 8 primeiros dígitos>` do
próprio ficheiro. Não é gosto: durante os testes o browser serviu uma
cópia velha do `comum-banco.js` e o comprovativo ficou preso em
"A carregar…" com um `formatarDataHora is not defined` que não aparecia em
lado nenhum. **Ao alterar um ficheiro local é preciso atualizar o `?v=`
nos HTML que o carregam**, senão volta o mesmo. Para conferir tudo de uma
vez:

```sh
for html in *.html; do
  grep -oE '(src|href)="([^"?]+)\?v=([0-9a-f]{8})"' "$html" | while read -r ref; do
    f=$(echo "$ref" | sed -E 's/.*="([^"?]+)\?v=.*/\1/')
    v=$(echo "$ref" | sed -E 's/.*\?v=([0-9a-f]{8})".*/\1/')
    r=$(sha1sum "$f" | cut -c1-8)
    [ "$v" != "$r" ] && echo "DESATUALIZADO $html -> $f ($v ≠ $r)"
  done
done
```

## Por fazer

- **Limpar a fuga de `sqlerrm`** nas ~25 funções que ainda devolvem o erro
  cru do Postgres ao browser (ver secção acima). É uma passagem
  mecânica mas atravessa todos os repos.
- Rever `fn_gerar_iban` no advisory de segurança (chamável por
  `anon`/`authenticated`, como as outras RPCs da porta única).
- Quando o `pp-criar-empresa` existir, passar a injetar o fundo inicial por
  `banco_creditar_inicial` em vez de escrever direto em `contas`.
