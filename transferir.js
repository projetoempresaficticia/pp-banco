// Prepacoin — transferência. A conta de origem é escolhida entre as que a
// pessoa controla; o servidor volta a validar isso de qualquer forma
// (banco_transferir compara com auth.uid(), nunca confia no parâmetro).

const seletorOrigem = document.getElementById('origem');
const infoOrigem = document.getElementById('info-origem');

let contas = []; // {cedula, rotulo, iban, saldo, pendente, limite}

async function carregarContas() {
  const { data: user } = await sb.auth.getUser();
  if (!user.user) return [];

  const { data: pessoa } = await sb
    .from('pessoas')
    .select('cedula, nome, empresa_id')
    .eq('id', user.user.id)
    .single();
  if (!pessoa) return [];

  const cedulas = [{ cedula: pessoa.cedula, rotulo: `${pessoa.nome} (pessoal)` }];
  if (pessoa.empresa_id) {
    const { data: empresa } = await sb
      .from('empresas')
      .select('cedula, nome')
      .eq('id', pessoa.empresa_id)
      .single();
    if (empresa) cedulas.push({ cedula: empresa.cedula, rotulo: `${empresa.nome} (empresa)` });
  }

  const resultado = [];
  for (const c of cedulas) {
    const r = await api('banco_saldo', { p_cedula: c.cedula });
    if (r.ok) {
      resultado.push({
        cedula: c.cedula,
        rotulo: c.rotulo,
        iban: r.dados.iban,
        saldo: Number(r.dados.saldo),
        pendente: Number(r.dados.pendente_saida || 0),
        limite: Number(r.dados.limite_aprovacao || 0),
      });
    }
  }
  return resultado;
}

function mostrarInfoOrigem() {
  const conta = contas.find((c) => c.iban === seletorOrigem.value);
  if (!conta) {
    infoOrigem.textContent = '';
    return;
  }
  const disponivel = conta.saldo - conta.pendente;
  const partes = [`Disponível: ${formatarP$(disponivel)}`];
  if (conta.pendente > 0) partes.push(`${formatarP$(conta.pendente)} preso em pendentes`);
  if (conta.limite > 0) partes.push(`acima de ${formatarP$(conta.limite)} precisa de aprovação`);
  infoOrigem.textContent = partes.join(' · ');
  infoOrigem.className = 'msg';
}

seletorOrigem.addEventListener('change', mostrarInfoOrigem);

document.getElementById('form-transferir').addEventListener('submit', async (ev) => {
  ev.preventDefault();
  const msg = document.getElementById('msg-transferir');
  const btn = document.getElementById('btn-transferir');

  const centimos = paraCentimos(document.getElementById('valor').value);
  if (centimos === null || centimos <= 0) {
    mostrarMsg(msg, 'Valor inválido. Use por exemplo 1250,00.', 'erro');
    return;
  }

  const destino = document.getElementById('destino').value.replace(/\s/g, '');
  if (!destino) {
    mostrarMsg(msg, 'Indique o IBAN de destino.', 'erro');
    return;
  }

  btn.disabled = true;
  mostrarMsg(msg, 'A transferir…', null);

  const r = await api('banco_transferir', {
    p_origem: seletorOrigem.value,
    p_destino: destino,
    p_valor: centimos,
    p_categoria: document.getElementById('categoria').value,
    p_descricao: document.getElementById('descricao').value || null,
  });

  btn.disabled = false;

  if (!r.ok) {
    mostrarMsg(msg, r.erro, 'erro');
    return;
  }

  if (r.dados.estado === 'pendente') {
    mostrarMsg(msg,
      'Transferência acima do limite: ficou pendente até um gerente aprovar.',
      'aviso');
  } else {
    mostrarMsg(msg,
      `Transferência concluída. Código do comprovante: ${r.dados.codigo}`,
      'sucesso');
  }

  document.getElementById('valor').value = '';
  document.getElementById('descricao').value = '';
  contas = await carregarContas();
  mostrarInfoOrigem();
});

async function verificarSessao() {
  const { data } = await sb.auth.getSession();
  if (!data.session) return;

  pcMostrarApp('Transferir');

  contas = await carregarContas();
  if (!contas.length) {
    document.getElementById('msg-transferir').textContent =
      'Ainda não tem nenhuma conta aberta no Prepacoin.';
    return;
  }
  seletorOrigem.innerHTML = contas
    .map((c) => `<option value="${c.iban}">${c.rotulo} — ${formatarIban(c.iban)}</option>`)
    .join('');
  mostrarInfoOrigem();
}

pcLigarEntrada(verificarSessao);
verificarSessao();
