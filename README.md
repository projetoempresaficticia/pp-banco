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
- `web/estilos.css` + `web/comum-banco.js` — paleta e utilitários
  (formatação de P$, IBAN e datas). O cliente Supabase vem do `comum.js`
  da pp-base, carregado cross-repo.
- Ícones reaproveitados do cache local da skill `figma-icons` — nenhuma
  chamada nova ao Figma (a cota do plano Starter é mensal).

## Por fazer

- Comprovante em PDF (hoje a verificação é a página pública; a skill também
  pede um PDF descarregável).
- Rever `fn_gerar_iban` no advisory de segurança (chamável por
  `anon`/`authenticated`, como as outras RPCs da porta única).
- Quando o `pp-criar-empresa` existir, passar a injetar o fundo inicial por
  `banco_creditar_inicial` em vez de escrever direto em `contas`.
