// Prepacoin — fila de transferências pendentes. A RLS já só devolve as
// transações das contas que a pessoa vê; a decisão em si é validada de
// novo no servidor (só gerente da empresa dona da conta de origem).

const areaAprovacoes = document.getElementById('area-aprovacoes');
const msgAprovacoes = document.getElementById('msg-aprovacoes');

async function carregarPendentes() {
  const alvo = document.getElementById('lista-pendentes');

  const { data, error } = await sb
    .from('transacoes')
    .select('id, origem_iban, destino_iban, valor, categoria, descricao, criada_em')
    .eq('estado', 'pendente')
    .order('criada_em', { ascending: false });

  if (error) {
    alvo.innerHTML = `<p class="vazio">Erro ao carregar: ${error.message}</p>`;
    return;
  }
  if (!data.length) {
    alvo.innerHTML = '<p class="vazio">Nada à espera de aprovação.</p>';
    return;
  }

  alvo.innerHTML = data
    .map((t) => `
      <div class="movimento">
        <div>
          <div class="mov-categoria">${t.categoria || 'transferência'} · ${formatarP$(t.valor)}</div>
          <div class="mov-detalhe">
            ${t.descricao ? t.descricao + ' · ' : ''}
            de ${formatarIban(t.origem_iban)} para ${formatarIban(t.destino_iban)}
            · ${formatarData(t.criada_em)}
          </div>
        </div>
        <div style="display:flex; gap:0.5rem; flex-shrink:0">
          <button type="button" style="margin:0" data-aprovar="${t.id}">
            <span class="icone i-aprovado"></span>
            Aprovar
          </button>
          <button type="button" class="perigo" style="margin:0" data-rejeitar="${t.id}">Rejeitar</button>
        </div>
      </div>`)
    .join('');

  alvo.querySelectorAll('[data-aprovar]').forEach((b) => {
    b.addEventListener('click', () => decidir(b.dataset.aprovar, true, b));
  });
  alvo.querySelectorAll('[data-rejeitar]').forEach((b) => {
    b.addEventListener('click', () => decidir(b.dataset.rejeitar, false, b));
  });
}

async function decidir(id, aprovar, botao) {
  botao.disabled = true;
  mostrarMsg(msgAprovacoes, aprovar ? 'A aprovar…' : 'A rejeitar…', null);

  const r = await api(aprovar ? 'banco_aprovar' : 'banco_rejeitar', { p_transacao_id: id });
  botao.disabled = false;

  if (!r.ok) {
    mostrarMsg(msgAprovacoes, r.erro, 'erro');
    return;
  }
  mostrarMsg(msgAprovacoes,
    aprovar
      ? `Aprovada. Código do comprovante: ${r.dados.codigo}`
      : 'Transferência rejeitada.',
    aprovar ? 'sucesso' : 'aviso');
  carregarPendentes();
}

async function verificarSessao() {
  const { data } = await sb.auth.getSession();
  if (!data.session) return;
  pcMostrarApp('Aprovações');
  areaAprovacoes.hidden = false;
  carregarPendentes();
}

pcLigarEntrada(verificarSessao);
verificarSessao();
