-- pp-banco — 0008 — dinheiro em P$ nas mensagens, e sem sqlerrm ao browser
--
-- Dois defeitos na mesma função, apanhados a pagar um boleto sem saldo:
--
-- 1. Recusava com "Saldo insuficiente (disponível: 0 cêntimos)." O valor
--    está certo — dinheiro é sempre bigint em cêntimos (R7 da pp-base) —
--    mas uma mensagem de erro é ecrã, e no ecrã o dinheiro escreve-se em
--    P$. Quem lê "4020 cêntimos" tem de fazer a conta de cabeça. A regra
--    continua inteira: guarda-se e calcula-se em cêntimos, formata-se à
--    saída.
--
-- 2. O handler devolvia `'Falha na transferência: ' || sqlerrm`. Isso é
--    uma exceção crua a chegar ao browser (R1 da pp-base): dá nomes de
--    colunas e de constraints a quem não devia vê-los, e não diz nada de
--    útil a um formando. Passa a mensagem fixa — o detalhe fica no log
--    do Postgres, que é onde serve para alguma coisa.
--
-- O resto do corpo é, à letra, o que estava aplicado — incluindo o
-- `for update` na conta de origem. A assinatura também: `p_categoria`
-- não tem default, e pô-lo aqui criaria uma segunda sobrecarga em vez de
-- substituir esta.

create or replace function public.fn_moeda(p_centimos bigint)
returns text
language plpgsql
immutable
as $$
declare
  -- to_char com formato fixo: o separador não pode depender do
  -- lc_numeric da sessão, senão a mensagem muda conforme quem chama
  v text := to_char(coalesce(p_centimos, 0) / 100.0, 'FM999999999990.00');
begin
  return 'P$ ' || replace(v, '.', ',');
end;
$$;

comment on function public.fn_moeda(bigint) is
  'Cêntimos → "P$ 1234,56", para mensagens que o utilizador lê. '
  'Nunca usar o resultado em contas: o valor vive em cêntimos.';

revoke execute on function public.fn_moeda(bigint) from public, anon;
grant  execute on function public.fn_moeda(bigint) to authenticated;

create or replace function public.banco_transferir(
  p_origem text, p_destino text, p_valor bigint,
  p_categoria text, p_descricao text default null
) returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_conta record; v_id uuid := gen_random_uuid(); v_codigo text;
  v_pendentes bigint; v_disponivel bigint; v_obrigacao boolean;
begin
  if auth.uid() is null then
    return jsonb_build_object('ok', false, 'erro', 'Sem sessão.');
  end if;
  if p_valor is null or p_valor <= 0 then
    return jsonb_build_object('ok', false, 'erro', 'Valor tem de ser positivo.');
  end if;
  if p_origem = p_destino then
    return jsonb_build_object('ok', false, 'erro', 'Origem e destino são a mesma conta.');
  end if;
  select * into v_conta from public.contas where iban = p_origem and estado = 'ativa' for update;
  if not found then
    return jsonb_build_object('ok', false, 'erro', 'Conta de origem inexistente ou bloqueada.');
  end if;
  if not public.fn_cedula_minha(v_conta.cedula) then
    return jsonb_build_object('ok', false, 'erro', 'Esta conta não é sua.');
  end if;
  if not exists (select 1 from public.contas where iban = p_destino and estado = 'ativa') then
    return jsonb_build_object('ok', false, 'erro', 'Conta de destino inexistente.');
  end if;
  select coalesce(sum(valor), 0) into v_pendentes
    from public.transacoes where origem_iban = p_origem and estado = 'pendente';
  v_disponivel := v_conta.saldo - v_pendentes;
  if v_disponivel < p_valor then
    v_obrigacao := coalesce(p_categoria, '') in ('salario', 'imposto', 'renda', 'utilities');
    insert into public.transacoes(id, origem_iban, destino_iban, valor, categoria, descricao, estado)
    values (v_id, p_origem, p_destino, p_valor, p_categoria, p_descricao, 'rejeitada');
    if v_obrigacao and v_conta.cedula like 'EP-%' then
      update public.empresas set estado = 'incumprimento'
        where cedula = v_conta.cedula and estado <> 'falida';
      return jsonb_build_object('ok', false, 'erro',
        'Saldo insuficiente para uma obrigação. Empresa marcada em incumprimento.');
    end if;
    return jsonb_build_object('ok', false, 'erro',
      format('Saldo insuficiente: tem %s disponíveis e são precisos %s.',
             public.fn_moeda(v_disponivel), public.fn_moeda(p_valor)));
  end if;
  if p_valor > coalesce(v_conta.limite_aprovacao, 9223372036854775807) then
    insert into public.transacoes(id, origem_iban, destino_iban, valor, categoria, descricao, estado)
    values (v_id, p_origem, p_destino, p_valor, p_categoria, p_descricao, 'pendente');
    return jsonb_build_object('ok', true, 'dados', jsonb_build_object(
      'id', v_id, 'estado', 'pendente', 'aviso', 'Acima do limite: aguarda aprovação de um gerente.'));
  end if;
  update public.contas set saldo = saldo - p_valor where iban = p_origem;
  update public.contas set saldo = saldo + p_valor where iban = p_destino;
  v_codigo := upper(left(encode(digest(v_id::text || now()::text, 'sha256'), 'hex'), 12));
  insert into public.transacoes(id, origem_iban, destino_iban, valor, categoria, descricao, estado, codigo_auth)
  values (v_id, p_origem, p_destino, p_valor, p_categoria, p_descricao, 'concluida', v_codigo);
  return jsonb_build_object('ok', true, 'dados', jsonb_build_object(
    'id', v_id, 'estado', 'concluida', 'codigo', v_codigo));
exception when others then
  return jsonb_build_object('ok', false, 'erro', 'Não foi possível concluir a transferência.');
end;
$$;
