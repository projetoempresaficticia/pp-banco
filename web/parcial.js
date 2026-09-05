// Prepacoin — as peças que as sete páginas repetem.
//
// O rail, a barra de topo e o ecrã de entrada eram os mesmos em todas as
// páginas, copiados à mão. Copiado à mão significa que uma correção só
// chega a algumas: foi assim que a navegação ficou diferente em cada
// ecrã. Aqui montam-se uma vez.

const PC_PAGINAS = [
  { href: 'index.html',      icone: 'i-conta',      nome: 'A minha conta' },
  { href: 'transferir.html', icone: 'i-transferir', nome: 'Transferir' },
  { href: 'boletos.html',    icone: 'i-recibo',     nome: 'Boletos' },
  { href: 'emitir.html',     icone: 'i-cartao',     nome: 'Emitir fatura' },
  { href: 'aprovacoes.html', icone: 'i-aprovado',   nome: 'Aprovações' },
];

function pcEscapar(s) {
  return String(s == null ? '' : s)
    .replace(/&/g, '&amp;').replace(/</g, '&lt;')
    .replace(/>/g, '&gt;').replace(/"/g, '&quot;');
}

// Qual página está aberta agora. Serve para o aria-current, que é o que
// diz a um leitor de ecrã onde a pessoa está.
function pcPaginaAtual() {
  const f = window.location.pathname.split('/').pop();
  return f === '' ? 'index.html' : f;
}

function pcMontarRail(alvo) {
  const atual = pcPaginaAtual();
  alvo.className = 'rail';
  alvo.setAttribute('aria-label', 'Navegação principal');
  alvo.innerHTML =
    '<div class="marca-pp rail-marca" aria-hidden="true"></div>' +
    PC_PAGINAS.map((p) => `
      <a href="${p.href}" title="${pcEscapar(p.nome)}"
         ${p.href === atual ? 'aria-current="page"' : ''}>
        <span class="icone icone-24 ${p.icone}"></span>
        <span class="so-leitores">${pcEscapar(p.nome)}</span>
      </a>`).join('');
}

function pcMontarBarra(alvo, titulo) {
  alvo.className = 'barra-topo';
  alvo.innerHTML = `
    <span class="marca">${pcEscapar(titulo || 'Prepacoin')}</span>
    <div class="fila">
      <span class="suave" id="pc-quem" style="font-size:13px"></span>
      <button type="button" class="botao-icone" id="btn-tema" title="Alternar tema">
        <span class="icone i-lua"></span><span class="so-leitores">Alternar tema</span>
      </button>
      <button type="button" class="secundario" id="btn-sair">Sair</button>
    </div>`;
}

// Escreve quem está com a sessão aberta. Sem isto, num laboratório onde
// vários formandos usam a mesma máquina, ninguém sabe em nome de quem
// está a mexer no dinheiro.
//
// Usa `getSession()` e não `getUser()` de propósito: o `getUser()` vai
// validar o token ao servidor, e duas chamadas em paralelo logo a seguir
// ao login entram em contenção. Uma delas devolvia `user: null` e este
// campo ficava em branco sem dar erro nenhum. O `getSession()` lê o que
// já está em memória e não tem esse problema.
async function pcMostrarQuem() {
  const el = document.getElementById('pc-quem');
  if (!el) return;
  const { data } = await sb.auth.getSession();
  const uid = data.session && data.session.user && data.session.user.id;
  if (!uid) return;

  const { data: p, error } = await sb.from('pessoas')
    .select('nome, cedula').eq('id', uid).single();
  if (error || !p) {
    // melhor o email do que um espaço em branco
    el.textContent = data.session.user.email || '';
    return;
  }
  el.textContent = `${p.nome} · ${p.cedula}`;
}

// Liga o botão Sair onde quer que ele esteja.
function pcLigarSair(antes) {
  const btn = document.getElementById('btn-sair');
  if (!btn) return;
  btn.addEventListener('click', async () => {
    if (typeof antes === 'function') antes();
    await sb.auth.signOut();
    window.location.reload();
  });
}

// Tudo o que as sete páginas fazem igual quando há sessão: esconder a
// entrada, mostrar a aplicação, montar a navegação e dizer quem entrou.
// Cada página só chama isto e trata do que é seu.
function pcMostrarApp(titulo, antesDeSair) {
  const entrada = document.getElementById('area-login');
  const app = document.getElementById('app');
  if (entrada) entrada.hidden = true;
  if (app) app.hidden = false;

  const rail = document.getElementById('rail');
  const barra = document.getElementById('barra');
  if (rail) pcMontarRail(rail);
  if (barra) pcMontarBarra(barra, titulo);

  pcLigarSair(antesDeSair);
  pcMostrarQuem();
}

/* ── janela ────────────────────────────────────────────────────────
   Ver um boleto ou um comprovativo abria uma aba nova, e obrigava a
   sair da página e a voltar. Passa a abrir aqui por cima, com o
   <dialog> nativo: o browser trata do foco preso lá dentro, do Escape
   a fechar e de tornar o resto da página inerte.

   O documento em si continua a viver em `documento.html`, e a janela
   carrega-o num <iframe>. É de propósito: assim há UM só sítio a
   desenhar o boleto, e o que se imprime é exatamente o que se vê. Um
   segundo desenho só para a janela ficava dessincronizado à primeira
   correção que alguém fizesse.
   ────────────────────────────────────────────────────────────────── */

function pcJanela() {
  let d = document.getElementById('pc-janela');
  if (d) return d;

  d = document.createElement('dialog');
  d.id = 'pc-janela';
  d.className = 'janela';
  d.innerHTML = `
    <div class="janela-cabeca">
      <h2 id="pc-janela-titulo">Documento</h2>
      <button type="button" class="botao-icone" id="pc-janela-fechar" title="Fechar">
        <span class="so-leitores">Fechar</span>
        <span aria-hidden="true" style="font-size:20px; line-height:1">&times;</span>
      </button>
    </div>
    <div class="janela-corpo" id="pc-janela-corpo"></div>
    <div class="janela-pe" id="pc-janela-pe"></div>`;
  document.body.appendChild(d);

  d.querySelector('#pc-janela-fechar').addEventListener('click', () => d.close());
  // clicar no escuro à volta também fecha
  d.addEventListener('click', (ev) => { if (ev.target === d) d.close(); });
  // largar o iframe ao fechar, para não ficar a consumir nada
  d.addEventListener('close', () => {
    const corpo = document.getElementById('pc-janela-corpo');
    corpo.classList.remove('so-documento');
    corpo.innerHTML = '';
  });
  return d;
}

// Abre `documento.html` numa janela por cima da página.
//   pcAbrirDocumento({ boleto: '20009-937456155' })
//   pcAbrirDocumento({ comprovante: 'FT-2026-000008' })
function pcAbrirDocumento(o) {
  const d = pcJanela();
  const alvo = o.boleto
    ? 'documento.html?boleto=' + encodeURIComponent(o.boleto)
    : 'documento.html?comprovante=' + encodeURIComponent(o.comprovante);

  document.getElementById('pc-janela-titulo').textContent =
    o.boleto ? 'Boleto' : 'Comprovativo';

  const corpo = document.getElementById('pc-janela-corpo');
  corpo.classList.add('so-documento');
  corpo.innerHTML =
    `<iframe id="pc-janela-doc" src="${alvo}" title="Documento"
             style="width:100%; height:min(70svh, 720px); border:0; display:block"></iframe>`;

  document.getElementById('pc-janela-pe').innerHTML = `
    <button type="button" class="secundario" id="pc-janela-cancelar">Fechar</button>
    <button type="button" id="pc-janela-imprimir">
      <span class="icone i-exportar"></span>Imprimir ou guardar PDF
    </button>`;

  document.getElementById('pc-janela-cancelar').onclick = () => d.close();
  document.getElementById('pc-janela-imprimir').onclick = () => {
    // imprimir o iframe, não a página: sai só a folha
    const f = document.getElementById('pc-janela-doc');
    if (f && f.contentWindow) { f.contentWindow.focus(); f.contentWindow.print(); }
  };

  d.showModal();
}

// Abre uma janela com conteúdo próprio (um formulário, por exemplo).
// Devolve o <dialog>, para quem chama ligar os seus botões.
function pcAbrirJanela(titulo, corpoHtml, peHtml) {
  const d = pcJanela();
  document.getElementById('pc-janela-titulo').textContent = titulo;
  const corpo = document.getElementById('pc-janela-corpo');
  corpo.classList.remove('so-documento');
  corpo.innerHTML = corpoHtml;
  document.getElementById('pc-janela-pe').innerHTML = peHtml || '';
  d.showModal();
  return d;
}

// O formulário de entrada é o mesmo nas sete páginas: mesmos ids, mesma
// mensagem de erro, mesma coisa a seguir.
function pcLigarEntrada(aoEntrar) {
  const form = document.getElementById('form-login');
  if (!form) return;
  form.addEventListener('submit', async (ev) => {
    ev.preventDefault();
    const msg = document.getElementById('msg-login');
    mostrarMsg(msg, 'A entrar…', null);
    const { error } = await sb.auth.signInWithPassword({
      email: document.getElementById('email').value,
      password: document.getElementById('senha').value,
    });
    if (error) { mostrarMsg(msg, 'Email ou senha incorretos.', 'erro'); return; }
    mostrarMsg(msg, '', null);
    await aoEntrar();
  });
}
