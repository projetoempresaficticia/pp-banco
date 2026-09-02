// Prepacoin — verificação pública de comprovante. banco_verificar_comprovante
// não exige sessão, e só devolve os últimos 4 dígitos de cada IBAN.

const resultado = document.getElementById('resultado');

document.getElementById('form-verificar').addEventListener('submit', async (ev) => {
  ev.preventDefault();
  const msg = document.getElementById('msg-verificar');
  const codigo = document.getElementById('codigo').value.trim();

  mostrarMsg(msg, 'A verificar…', null);
  resultado.hidden = true;

  const r = await api('banco_verificar_comprovante', { p_codigo: codigo });

  if (!r.ok) {
    mostrarMsg(msg, r.erro, 'erro');
    return;
  }
  mostrarMsg(msg, '', null);

  const d = r.dados;
  resultado.classList.remove('selo-ok', 'selo-erro');
  resultado.classList.add(d.valido ? 'selo-ok' : 'selo-erro');

  document.getElementById('v-titulo').textContent =
    d.valido ? 'Comprovante válido' : 'Transferência não concluída';
  document.getElementById('v-subtitulo').textContent =
    d.valido
      ? 'Esta transferência foi mesmo concluída pelo Prepacoin.'
      : `Existe, mas está no estado "${d.estado}" — o dinheiro não foi movido.`;

  document.getElementById('v-valor').textContent = formatarP$(d.valor);
  document.getElementById('v-categoria').textContent = d.categoria || '—';
  document.getElementById('v-data').textContent = formatarData(d.criada_em);
  document.getElementById('v-contas').textContent =
    `de …${d.origem_final || '----'} para …${d.destino_final || '----'}`;

  resultado.hidden = false;
});

// código na URL (?codigo=…) abre já verificado, para o link do comprovante
const codigoUrl = new URLSearchParams(window.location.search).get('codigo');
if (codigoUrl) {
  document.getElementById('codigo').value = codigoUrl;
  document.getElementById('form-verificar').dispatchEvent(new Event('submit'));
}
