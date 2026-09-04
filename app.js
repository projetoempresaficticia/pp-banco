// Prepacoin — o painel da conta: saldo, para onde vai o dinheiro,
// movimento por dia, o que está por pagar e o extrato.
//
// Os quatro gráficos saem todos do MESMO extrato que a lista já usava.
// Nada aqui é inventado nem arredondado para ficar bonito: se o gráfico
// e a lista discordarem, um dos dois está com um bug, e é isso que se
// quer. Números falsos num app que ensina contabilidade seriam a pior
// lição possível.

const areaLogin = document.getElementById('area-login');
const app = document.getElementById('app');
const areaConta = document.getElementById('area-conta');
const areaSemConta = document.getElementById('area-sem-conta');
const formLogin = document.getElementById('form-login');
const msgLogin = document.getElementById('msg-login');
const seletorConta = document.getElementById('seletor-conta');

let cedulasDisponiveis = [];
let cedulaAtual = null;
let canalRealtime = null;

function esc(s) {
  return String(s == null ? '' : s)
    .replace(/&/g, '&amp;').replace(/</g, '&lt;')
    .replace(/>/g, '&gt;').replace(/"/g, '&quot;');
}

/* ── quais contas esta pessoa pode ver ───────────────────────────── */

async function carregarCedulas() {
  const { data: user } = await sb.auth.getUser();
  if (!user.user) return [];

  const { data: pessoa } = await sb
    .from('pessoas').select('cedula, nome, empresa_id')
    .eq('id', user.user.id).single();
  if (!pessoa) return [];

  const lista = [{ cedula: pessoa.cedula, rotulo: `${pessoa.nome} (pessoal)` }];

  if (pessoa.empresa_id) {
    const { data: empresa } = await sb
      .from('empresas').select('cedula, nome')
      .eq('id', pessoa.empresa_id).single();
    if (empresa) lista.push({ cedula: empresa.cedula, rotulo: `${empresa.nome} (empresa)` });
  }
  return lista;
}

function desenharSeletor() {
  if (cedulasDisponiveis.length < 2) { seletorConta.hidden = true; return; }
  seletorConta.hidden = false;
  seletorConta.innerHTML = cedulasDisponiveis
    .map((c) => `<option value="${esc(c.cedula)}" ${c.cedula === cedulaAtual ? 'selected' : ''}>${esc(c.rotulo)}</option>`)
    .join('');
}

/* ── gráficos, todos derivados do extrato ────────────────────────── */

const SERIES = ['var(--pc-s1)', 'var(--pc-s2)', 'var(--pc-s3)', 'var(--pc-s4)', 'var(--pc-s5)'];

// Só contam as saídas concluídas: uma transferência recusada não gastou
// nada, e metê-la aqui dizia ao formando que o dinheiro saiu.
function repartirPorCategoria(movimentos) {
  const soma = {};
  for (const m of movimentos) {
    if (m.sentido !== 'saida' || m.estado !== 'concluida') continue;
    const k = m.categoria || 'sem categoria';
    soma[k] = (soma[k] || 0) + Number(m.valor);
  }
  const linhas = Object.entries(soma).sort((a, b) => b[1] - a[1]);
  const total = linhas.reduce((s, [, v]) => s + v, 0);
  return { linhas, total };
}

function desenharCategorias(movimentos) {
  const alvo = document.getElementById('c-categorias');
  const { linhas, total } = repartirPorCategoria(movimentos);

  if (!total) {
    alvo.innerHTML = '<p class="vazio">Ainda não saiu dinheiro desta conta.</p>';
    return;
  }

  // as cinco maiores; o resto junta-se para a barra somar sempre 100%
  const topo = linhas.slice(0, 4);
  const resto = linhas.slice(4).reduce((s, [, v]) => s + v, 0);
  if (resto > 0) topo.push(['outras', resto]);

  const seg = topo.map(([, v], i) =>
    `<span style="width:${(v / total * 100).toFixed(2)}%; background:${SERIES[i]}"></span>`).join('');

  const leg = topo.map(([k, v], i) => `
    <span class="legenda-item">
      <span class="legenda-marca" style="background:${SERIES[i]}"></span>
      ${esc(k)} ${Math.round(v / total * 100)}%
    </span>`).join('');

  alvo.innerHTML = `
    <div class="barra-seg" role="img"
         aria-label="Repartição das saídas: ${esc(topo.map(([k, v]) => `${k} ${Math.round(v / total * 100)} por cento`).join(', '))}">
      ${seg}
    </div>
    <div class="legenda">${leg}</div>
    <p class="ajuda">Total saído: <strong>${formatarP$(total)}</strong></p>`;
}

function desenharFluxo(movimentos) {
  const alvo = document.getElementById('c-fluxo');
  let entrou = 0, saiu = 0;
  for (const m of movimentos) {
    if (m.estado !== 'concluida') continue;
    if (m.sentido === 'entrada') entrou += Number(m.valor);
    else saiu += Number(m.valor);
  }
  if (!entrou && !saiu) {
    alvo.innerHTML = '<p class="vazio">Sem movimentos concluídos.</p>';
    return;
  }

  const maior = Math.max(entrou, saiu);
  const pct = (v) => maior ? Math.max(4, v / maior * 100) : 0;

  alvo.innerHTML = `
    <div class="pilha" style="gap:var(--pc-e4)">
      <div>
        <div class="fila" style="justify-content:space-between">
          <span class="suave" style="font-size:12px">Entrou</span>
          <strong class="numero">${formatarP$(entrou)}</strong>
        </div>
        <div class="barra-seg" style="margin:6px 0 0">
          <span style="width:${pct(entrou)}%; background:var(--pc-ok)"></span>
        </div>
      </div>
      <div>
        <div class="fila" style="justify-content:space-between">
          <span class="suave" style="font-size:12px">Saiu</span>
          <strong class="numero">${formatarP$(saiu)}</strong>
        </div>
        <div class="barra-seg" style="margin:6px 0 0">
          <span style="width:${pct(saiu)}%; background:var(--pc-s1)"></span>
        </div>
      </div>
      <div class="fila" style="justify-content:space-between; border-top:1px solid var(--pc-linha-suave); padding-top:var(--pc-e3)">
        <span class="suave" style="font-size:12px">Diferença</span>
        <strong class="numero" style="color:${entrou - saiu >= 0 ? 'var(--pc-ok)' : 'var(--pc-erro)'}">
          ${entrou - saiu >= 0 ? '+' : '-'} ${formatarP$(Math.abs(entrou - saiu))}
        </strong>
      </div>
    </div>`;
}

const DIAS = ['Dom', 'Seg', 'Ter', 'Qua', 'Qui', 'Sex', 'Sáb'];

function desenharSemana(movimentos) {
  const alvo = document.getElementById('c-semana');
  const porDia = [0, 0, 0, 0, 0, 0, 0];
  for (const m of movimentos) {
    if (m.estado !== 'concluida') continue;
    porDia[new Date(m.criada_em).getDay()] += Number(m.valor);
  }
  const maior = Math.max(...porDia);
  if (!maior) {
    alvo.innerHTML = '<p class="vazio">Sem movimentos concluídos.</p>';
    return;
  }

  // a semana começa à segunda, como em Portugal
  const ordem = [1, 2, 3, 4, 5, 6, 0];
  const colunas = ordem.map((d) => {
    const v = porDia[d];
    const alto = v === maior;
    return `
      <div class="barra-col ${alto ? 'destaque' : ''}" title="${DIAS[d]}: ${formatarP$(v)}">
        <div class="haste" style="height:${maior ? Math.max(3, v / maior * 100) : 0}%"></div>
        <span class="dia">${DIAS[d]}</span>
      </div>`;
  }).join('');

  alvo.innerHTML = `
    <div class="barras-v" role="img"
         aria-label="Movimento por dia da semana. Maior: ${esc(DIAS[porDia.indexOf(maior)])}, ${esc(formatarP$(maior))}.">
      ${colunas}
    </div>
    <p class="ajuda">Dia mais movimentado: <strong>${DIAS[porDia.indexOf(maior)]}</strong>, ${formatarP$(maior)}.</p>`;
}

async function desenharBoletos() {
  const alvo = document.getElementById('c-boletos');
  const r = await api('banco_boletos_por_pagar', { p_cedula: cedulaAtual });

  if (!r.ok) { alvo.innerHTML = `<p class="vazio">${esc(r.erro)}</p>`; return; }

  const lista = r.dados.boletos || [];
  if (!lista.length) {
    alvo.innerHTML = `
      <div class="centro" style="padding:var(--pc-e5) 0">
        <span class="icone icone-24 i-aprovado" style="color:var(--pc-ok)"></span>
        <p class="suave" style="margin:var(--pc-e2) 0 0">Nada por pagar.</p>
      </div>`;
    return;
  }

  const total = lista.reduce((s, b) => s + Number(b.valor), 0);
  const atrasados = lista.filter((b) => b.atrasado).length;

  alvo.innerHTML = `
    <p class="cartao-saldo numero" style="color:var(--pc-texto); font-size:28px">${formatarP$(total)}</p>
    <p class="suave" style="margin:6px 0 var(--pc-e3)">
      ${lista.length} ${lista.length === 1 ? 'boleto' : 'boletos'}${atrasados ? `, ${atrasados} em atraso` : ''}
    </p>
    ${lista.slice(0, 3).map((b) => `
      <div class="movimento" style="padding:var(--pc-e2) 0">
        <div>
          <div class="mov-categoria" style="font-size:13px">${esc(b.descricao || 'boleto')}</div>
          <div class="mov-detalhe">${esc(b.emitente_nome)}${b.atrasado ? ' · <span class="vencido">em atraso</span>' : ''}</div>
        </div>
        <div class="mov-valor saida numero" style="font-size:13px">${formatarP$(b.valor)}</div>
      </div>`).join('')}`;
}

/* ── conta e extrato ─────────────────────────────────────────────── */

async function carregarConta() {
  const msg = document.getElementById('msg-conta');
  mostrarMsg(msg, '', null);

  const r = await api('banco_saldo', { p_cedula: cedulaAtual });
  if (!r.ok) {
    if (r.erro && r.erro.includes('ainda não tem conta')) {
      areaConta.hidden = true;
      areaSemConta.hidden = false;
      return;
    }
    areaConta.hidden = true;
    mostrarMsg(msg, r.erro, 'erro');
    return;
  }

  areaSemConta.hidden = true;
  areaConta.hidden = false;

  const d = r.dados;
  const disponivel = Number(d.saldo) - Number(d.pendente_saida || 0);
  document.getElementById('c-saldo').textContent = formatarP$(disponivel);
  document.getElementById('c-iban').textContent = formatarIban(d.iban);
  document.getElementById('c-estado').hidden = false;

  document.getElementById('c-preso').textContent = Number(d.pendente_saida) > 0
    ? `${formatarP$(d.pendente_saida)} à espera de aprovação, de ${formatarP$(d.saldo)} em conta`
    : 'Nada preso em pendentes';

  const daEmpresa = cedulaAtual && cedulaAtual.startsWith('EP-');
  document.getElementById('titulo-conta').textContent =
    daEmpresa ? 'Conta da empresa' : 'A minha conta';

  await carregarMovimentos();
  await desenharBoletos();
  ligarRealtime(d.iban);
}

async function carregarMovimentos() {
  const alvo = document.getElementById('lista-movimentos');
  const r = await api('banco_extrato', { p_cedula: cedulaAtual, p_limite: 30 });

  if (!r.ok) {
    alvo.innerHTML = `<p class="vazio">Não foi possível carregar: ${esc(r.erro)}</p>`;
    return;
  }
  const movimentos = r.dados.movimentos || [];

  desenharCategorias(movimentos);
  desenharFluxo(movimentos);
  desenharSemana(movimentos);

  if (!movimentos.length) {
    alvo.innerHTML = '<p class="vazio">Sem movimentos ainda.</p>';
    return;
  }

  alvo.innerHTML = movimentos.map((m) => {
    const entrada = m.sentido === 'entrada';
    const classeValor = m.estado === 'rejeitada' ? 'anulado' : entrada ? 'entrada' : 'saida';
    const contraparte = m.contraparte === 'emissão'
      ? 'emissão do banco' : formatarIban(m.contraparte);
    return `
      <div class="movimento">
        <div class="mov-marca">
          <span class="icone ${entrada ? 'i-seta-baixo' : 'i-seta-cima'}"></span>
        </div>
        <div>
          <div class="mov-categoria">
            ${esc(m.categoria || 'transferência')} ${badgeEstado(m.estado)}
          </div>
          <div class="mov-detalhe">
            ${m.descricao ? esc(m.descricao) + ' · ' : ''}${entrada ? 'de' : 'para'} ${esc(contraparte)}
            · ${formatarData(m.criada_em)}
            ${m.codigo_auth ? `· <span class="codigo-auth">${esc(m.codigo_auth)}</span>` : ''}
          </div>
        </div>
        <div class="mov-valor ${classeValor} numero">
          ${entrada ? '+' : '-'} ${formatarP$(m.valor)}
        </div>
      </div>`;
  }).join('');
}

// Saldo em tempo real, em vez de recarregar a página.
function ligarRealtime(iban) {
  if (canalRealtime) { sb.removeChannel(canalRealtime); canalRealtime = null; }
  canalRealtime = sb
    .channel('prepacoin-' + iban)
    .on('postgres_changes',
      { event: '*', schema: 'public', table: 'transacoes' },
      () => carregarConta())
    .subscribe();
}

/* ── ligações ────────────────────────────────────────────────────── */

seletorConta.addEventListener('change', () => {
  cedulaAtual = seletorConta.value;
  carregarConta();
});

document.getElementById('btn-abrir-conta').addEventListener('click', async (ev) => {
  const msg = document.getElementById('msg-abrir');
  ev.target.disabled = true;
  mostrarMsg(msg, 'A abrir a conta…', null);

  const r = await api('banco_abrir_conta', { p_cedula: cedulaAtual, p_limite: 100000 });
  ev.target.disabled = false;

  if (!r.ok) { mostrarMsg(msg, r.erro, 'erro'); return; }
  mostrarMsg(msg, 'Conta aberta. IBAN ' + formatarIban(r.dados.iban), 'ok');
  carregarConta();
});

async function verificarSessao() {
  const { data } = await sb.auth.getSession();
  if (!data.session) return;

  areaLogin.hidden = true;
  app.hidden = false;

  pcMontarRail(document.getElementById('rail'));
  pcMontarBarra(document.getElementById('barra'), 'Prepacoin');
  pcLigarSair(() => { if (canalRealtime) sb.removeChannel(canalRealtime); });
  pcMostrarQuem();

  cedulasDisponiveis = await carregarCedulas();
  if (!cedulasDisponiveis.length) {
    areaConta.hidden = false;
    mostrarMsg(document.getElementById('msg-conta'),
      'Esta conta de acesso ainda não tem ficha na Carteirinha.', 'erro');
    return;
  }
  cedulaAtual = cedulasDisponiveis[0].cedula;
  desenharSeletor();
  carregarConta();
}

formLogin.addEventListener('submit', async (ev) => {
  ev.preventDefault();
  mostrarMsg(msgLogin, 'A entrar…', null);
  const { error } = await sb.auth.signInWithPassword({
    email: document.getElementById('email').value,
    password: document.getElementById('senha').value,
  });
  if (error) { mostrarMsg(msgLogin, 'Email ou senha incorretos.', 'erro'); return; }
  mostrarMsg(msgLogin, '', null);
  await verificarSessao();
});

verificarSessao();
