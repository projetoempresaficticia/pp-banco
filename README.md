# pp-banco

Banco **Prepacoin** — contas, IBAN PT50, transferências em P$ (Prepara Portugal)

**Status:** backend e frontend construídos e testados de ponta a ponta com
sessões reais (abertura de conta, emissão de fundo, transferência,
limite→aprovação, incumprimento, extrato, comprovante público, fatura com
linhas, boleto por entidade+referência e cancelamento). Frontend
redesenhado sobre a biblioteca própria em 2026-09-04.
**Depende de:** [pp-base](https://github.com/projetoempresaficticia/pp-base),
[classcard](https://github.com/projetoempresaficticia/classcard) (pp-identidade)

Site: https://projetoempresaficticia.github.io/pp-banco/

Documentação completa (PRDs e decisões) em
[prepara-portugal-docs](https://github.com/projetoempresaficticia/prepara-portugal-docs).

## Identidade visual

**Mudou em 2026-09-04** (decisão do Germano). O Prepacoin adotou por
inteiro o kit **Nexus Bank**; a paleta Purse violeta/laranja que aqui
esteve (`#8F41DE`, `#FF7535`) já não é a do banco.

- Nome do produto: **Prepacoin**
- Lima `#EBFF78` · Tinta `#0A0C10` · Neutro claro `#667085` · Neutro
  escuro `#98A2B3` · Linha `#DADADA`
- **Inter** (400/500/600) no texto, **Sora** (600/700) no display e no
  dinheiro
- Tema claro por omissão, escuro quando o sistema o pede, e a escolha
  explícita do utilizador vence as duas

A biblioteca está em `web/biblioteca/prepacoin.css` e a montra em
[biblioteca.html](https://projetoempresaficticia.github.io/pp-banco/biblioteca.html).

### A regra que decide o resto

O lima tem **1,10:1** de contraste sobre branco. Não é gosto, é medição:
no tema claro **desaparece** como texto. Só pode ser preenchimento, e
sempre com a tinta por cima, onde dá 17,81:1.

Daí a lei que atravessa a biblioteca inteira:

| | quem carrega a ênfase | o que o lima faz |
|---|---|---|
| tema claro | a tinta `#0A0C10` | preenche, com tinta por cima |
| tema escuro | o lima `#EBFF78` | preenche **e** escreve |

É o mesmo `#0A0C10` a trocar de papel entre tinta e chão. Foi assim que o
kit original o desenhou, e é por isso que funciona.

Cores do kit que **reprovam** no tema claro e por isso ficam reservadas ao
escuro: `#98A2B3` (2,58:1), `#34C759` (2,22:1), `#C7E046` (1,48:1). Para o
claro há substitutas medidas: `#1A7F37` (5,08:1), `#B42318` (6,57:1),
`#B54708` (5,43:1).

### Duas armadilhas que esta biblioteca já resolveu

**A série dos gráficos existe por um bug.** No tema claro `--pc-enfase` e
`--pc-texto` são a **mesma cor**, e o primeiro gráfico de categorias saiu
com "Salários" e "Impostos" indistinguíveis. Daí `--pc-s1` a `--pc-s5`,
cada uma medida contra o painel do seu tema. O que as separa entre si é o
matiz, não a luminância, e por isso a legenda leva sempre texto e
percentagem: a cor nunca conta a história sozinha.

**O `url()` dos ícones está declarado no CSS, nunca no HTML.** Um `url()`
dentro de uma custom property resolve-se relativo à folha onde foi
declarado. Declará-lo no HTML partia todos os caminhos, que foi o bug que
apagou os ícones do Cartório.

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

Todas as páginas partilham o mesmo esqueleto: rail de ícones à esquerda,
barra de topo com quem está com a sessão aberta, e o mesmo ecrã de entrada
(quem chega a `boletos.html` sem sessão entra ali e **fica ali**, em vez de
ser atirado para o index). O rail e a barra são montados por
`web/parcial.js`, não copiados página a página.

- `index.html`/`app.js` — painel da conta: cartão com saldo disponível e
  IBAN, seletor entre a conta pessoal e a da empresa, e quatro leituras
  **todas derivadas do mesmo extrato que a lista já usava**: para onde vai
  o dinheiro (barra por categoria), entradas contra saídas, movimento por
  dia da semana, e o que está por pagar. Nada aqui é inventado nem
  arredondado para ficar bonito: se um gráfico e a lista discordarem, um
  dos dois tem um bug, e é isso que se quer. Números falsos num app que
  ensina contabilidade seriam a pior lição possível. Só contam as
  transferências **concluídas**: uma recusada não gastou nada. Saldo em
  tempo real via Supabase Realtime.
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
- `biblioteca.html` — a montra da biblioteca: a regra do contraste com a
  prova lado a lado, cores, tipografia, ícones, botões, formulários,
  estados, gráficos e raios. É por aqui que se começa antes de desenhar
  um ecrã novo.
- `web/biblioteca/prepacoin.css` — a biblioteca. Tokens dos dois temas,
  esqueleto, componentes, gráficos e a folha A4.
- `web/parcial.js` — rail, barra de topo, ecrã de entrada e quem está com
  a sessão aberta. Existiam copiados em cada página, e por isso tinham
  ficado diferentes uns dos outros.
- `web/tema.js` — o alternador. Três estados, não dois: sistema (por
  omissão), claro e escuro. Só a escolha explícita escreve `data-tema` na
  raiz.
- `web/comum-banco.js` — formatação de P$, IBAN e datas, e os badges de
  estado. O cliente Supabase vem do `comum.js` da pp-base, cross-repo.
- `web/icones/` — 22 ícones **Vuesax**, exportados do kit Nexus pela API
  REST do Figma numa só chamada. Pintados por `mask-image`, seguem o
  `currentColor` e trocam de tema sozinhos.

## Fatura e boleto são coisas diferentes

`sql/0010_boleto_avulso.sql` — correção de conceito pedida pelo Germano
(2026-09-04). Estavam colados: a única forma de criar um boleto era
emitir uma fatura com linhas.

| | O que é | Quando se usa |
|---|---|---|
| **Fatura** | Diz o quê e quanto, item a item. O documento comercial. | 20 pães a 1,50 e 12 bolos a 0,85 |
| **Boleto** | A ordem de pagamento: entidade, referência, valor, prazo. | Sempre. Sai de uma fatura, ou sozinho |

Uma fatura gera sempre um boleto. Um boleto **não** precisa de fatura:
uma taxa, uma quota ou um acerto é só um valor a pagar até uma data, e
obrigar a discriminar linhas para cobrar P$ 15 é papelada a mais. Daí o
`banco_emitir_boleto`, e o botão "Emitir boleto" na página dos boletos.

**Sem ilusões sobre a implementação:** o boleto avulso continua pendurado
numa linha de `faturas`, porque é aí que vive o rasto de quem cobrou a
quem e se foi pago. O que muda é que essa linha fica marcada com
`servico = 'boleto_avulso'`, e a partir daí os ecrãs e o papel dizem a
verdade sobre o que estão a mostrar: a lista escreve "Boleto avulso" em
vez de "Fatura FT-…", e o documento impresso sai com o cabeçalho
"Boleto de cobrança".

## A colisão de `.entrada`

Vale a pena guardar, porque não deu erro nenhum e custou a encontrar.

As linhas de crédito do extrato usam `.mov-valor.entrada` desde sempre.
Ao escrever a biblioteca, o ecrã de login ficou com a classe `.entrada`,
que traz `min-height: 100svh`. Duas regras diferentes, cada uma sem saber
da outra, a acertar no mesmo `<td>`: cada célula de entrada do extrato
passou a medir uma altura de ecrã inteira, e a tabela ficou com linhas de
570px para conteúdo de 40px.

O que despistou: esvaziar as células **não mudava nada**, porque a altura
não vinha do conteúdo. Só medindo caso a caso é que apareceu, e o
culpado foi o nome curto demais. O ecrã de login passou a `.ecra-entrada`.

**Regra:** uma classe de layout global nunca deve ter um nome que uma
classe de dados possa querer. Se `.entrada` descreve um movimento
bancário neste projeto, não pode descrever também um ecrã.

## Documentos em janela, não em aba nova

Ver um boleto abria `documento.html` noutra aba e obrigava a sair da
página e a voltar. Passa a abrir numa janela por cima, com o `<dialog>`
nativo: o browser trata sozinho do foco preso lá dentro, do Escape a
fechar e de tornar o resto da página inerte.

A janela carrega o `documento.html` num `<iframe>`, de propósito. Assim
há **um só sítio** a desenhar o boleto, e o que se imprime é exatamente o
que se vê. Um segundo desenho só para a janela ficava dessincronizado à
primeira correção que alguém fizesse. Dentro da janela o documento
esconde a sua própria barra de ações, para não haver dois pares de
"Voltar / Imprimir" ao mesmo tempo.

## Ferramentas

```sh
python ferramentas/versoes.py            # carimba os ?v= com o sha1 real
python ferramentas/versoes.py --conferir # só verifica, devolve 1 se falhar
python ferramentas/gerar_paginas.py      # regera as 4 páginas do molde
```

**Ao alterar um ficheiro local, correr `versoes.py`.** Cada
`<script>`/`<link>` local leva `?v=<sha1>` do próprio ficheiro, e não é
gosto: durante os testes o browser serviu uma cópia velha do
`comum-banco.js` e o comprovativo ficou preso em "A carregar…" com um
`formatarDataHora is not defined` que não aparecia em lado nenhum. Fazer
isto à mão em 8 páginas por 5 ficheiros falha, e por isso é um script.

### O buraco que o `?v=` não tapa

O `?v=` protege o CSS e o JS. **Não protege o HTML**, que é a porta de
entrada. O GitHub Pages manda `Cache-Control: max-age=600` no HTML e não
deixa mudar isso: durante dez minutos o browser serve a página guardada
sem sequer perguntar ao servidor. E como é o HTML que diz quais são os
`?v=`, um HTML velho aponta para ficheiros velhos e a página inteira fica
presa. O Germano viu a lista de boletos com o desenho antigo horas depois
de ele ter sido substituído.

`versoes.py` escreve por isso um `versao.json` e um
`<meta name="pc-versao">` em cada página, ambos com o resumo de tudo o
que está versionado. O `web/atualizar.js` compara os dois ao abrir a
página (com `cache: 'no-store'`, que obriga a ir mesmo ao servidor) e, se
não baterem certo, recarrega com a versão no endereço. Endereço diferente
quer dizer entrada diferente na cache, por isso o browser vai buscar o
HTML novo em vez de reusar o velho.

Recarrega **no máximo uma vez por página e por versão**, guardado em
`sessionStorage`, para nunca entrar em ciclo. Sem rede, segue com o que
tem: mais vale a página velha do que página nenhuma.

> Nota para quem mexer no `versoes.py`: o resumo do site exclui o próprio
> `<meta>` **e o espaço em branco à frente dele**. Sem isso é circular
> (escrever a versão muda o ficheiro, que muda a versão) e o script nunca
> estabiliza. `python ferramentas/versoes.py --conferir` tem de devolver
> 0 à segunda passagem.

O `gerar_paginas.py` escreve `transferir`, `boletos`, `emitir` e
`aprovacoes` a partir de um molde comum. O `index` e a `biblioteca` ficam
de fora: o primeiro tem um painel de conta que não se parece com nenhum
outro, a segunda é a montra. O molde existe porque o rail e a barra de
topo, escritos à mão em cada página, tinham ficado diferentes uns dos
outros, com navegações que não batiam certo.

## Por fazer

- **Confirmar o desenho num telemóvel a sério.** As regras de telemóvel
  existem (abaixo de 720px o rail passa a barra inferior, com
  `env(safe-area-inset-bottom)`), e nenhuma página transborda na
  horizontal, mas o `agent-browser` desta máquina não controla o viewport
  e por isso o ecrã pequeno **não foi visto**, só lido no CSS.
- **Limpar a fuga de `sqlerrm`** nas ~25 funções que ainda devolvem o erro
  cru do Postgres ao browser (ver secção acima). É uma passagem
  mecânica mas atravessa todos os repos.
- Rever `fn_gerar_iban` no advisory de segurança (chamável por
  `anon`/`authenticated`, como as outras RPCs da porta única).
- Quando o `pp-criar-empresa` existir, passar a injetar o fundo inicial por
  `banco_creditar_inicial` em vez de escrever direto em `contas`.
