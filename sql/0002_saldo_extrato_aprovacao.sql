-- Prepacoin (pp-banco) — completa as RPCs que a skill especifica e que
-- não existiam na base: saldo, extrato, aprovar/rejeitar com os nomes da
-- spec, e a porta de emissão de saldo inicial.
--
-- Sobre a emissão: a skill diz "saldo inicial 0 (o fundo inicial entra
-- por transferência do fundo de investimento)", e quem injeta esse fundo
-- é o `pp-criar-empresa` (app #10, ainda por construir), que faz
-- `update contas set saldo = saldo + fundo`. Ou seja, hoje não há
-- nenhuma forma de dinheiro entrar no sistema — o banco não arranca nem
-- para teste. `banco_creditar_inicial` é essa porta, restrita ao
-- professor, e é a mesma que o pp-criar-empresa vai usar quando existir
-- (em vez de escrever direto na tabela, que fura a porta única).
--
-- `banco_aprovar` / `banco_rejeitar` são os nomes que a skill define;
-- ficam como invólucros finos sobre `banco_decidir_pendente` (0001) para
-- não duplicar a lógica de validação e movimento de dinheiro.
-- Aplicada ao Supabase do projeto (moxxbehwylcjaqjacmyh) em 2026-09-02.

-- ---------------------------------------------------------------------
-- banco_creditar_inicial: única porta de entrada de dinheiro novo.
-- Só professor. Regista a entrada como transação (origem nula = emissão)
-- para o dinheiro nunca aparecer do nada sem rasto no extrato.
-- ---------------------------------------------------------------------
create or replace function public.banco_creditar_inicial(
  p_cedula text,
  p_valor bigint,
  p_descricao text default 'Fundo inicial'
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_conta record;
  v_id uuid := gen_random_uuid();
  v_codigo text;
begin
  if auth.uid() is null then
    return jsonb_build_object('ok', false, 'erro', 'Sem sessão.');
  end if;
  if not public.fn_e_professor() then
    return jsonb_build_object('ok', false, 'erro', 'Só o professor pode emitir fundo inicial.');
  end if;
  if p_valor is null or p_valor <= 0 then
    return jsonb_build_object('ok', false, 'erro', 'Valor tem de ser positivo.');
  end if;

  select * into v_conta from public.contas where cedula = p_cedula for update;
  if not found then
    return jsonb_build_object('ok', false, 'erro', 'Conta inexistente para ' || p_cedula);
  end if;

  update public.contas set saldo = saldo + p_valor where cedula = p_cedula;

  v_codigo := upper(left(encode(digest(v_id::text || now()::text, 'sha256'), 'hex'), 12));
  insert into public.transacoes(id, origem_iban, destino_iban, valor, categoria, descricao, estado, codigo_auth)
  values (v_id, null, v_conta.iban, p_valor, 'emissao', p_descricao, 'concluida', v_codigo);

  return jsonb_build_object('ok', true, 'dados', jsonb_build_object(
    'iban', v_conta.iban, 'saldo', v_conta.saldo + p_valor, 'codigo', v_codigo));
exception when others then
  return jsonb_build_object('ok', false, 'erro', 'Falha ao creditar: ' || sqlerrm);
end;
$$;

-- ---------------------------------------------------------------------
-- banco_saldo: saldo + IBAN de uma conta. Só o dono, alguém da empresa
-- dona, ou o professor.
-- ---------------------------------------------------------------------
create or replace function public.banco_saldo(p_cedula text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_cedula text;
  v_conta record;
begin
  if auth.uid() is null then
    return jsonb_build_object('ok', false, 'erro', 'Sem sessão.');
  end if;

  -- sem parâmetro, devolve a conta da própria pessoa logada
  v_cedula := coalesce(p_cedula, public.fn_minha_cedula());
  if v_cedula is null then
    return jsonb_build_object('ok', false, 'erro', 'Sem ficha na Carteirinha.');
  end if;

  if not (
    public.fn_e_professor()
    or v_cedula in (public.fn_minha_cedula(), public.fn_minha_empresa_cedula())
  ) then
    return jsonb_build_object('ok', false, 'erro', 'Sem acesso a esta conta.');
  end if;

  select * into v_conta from public.contas where cedula = v_cedula;
  if not found then
    return jsonb_build_object('ok', false, 'erro', 'Esta cédula ainda não tem conta.');
  end if;

  return jsonb_build_object('ok', true, 'dados', jsonb_build_object(
    'cedula', v_conta.cedula,
    'iban', v_conta.iban,
    'saldo', v_conta.saldo,
    'limite_aprovacao', v_conta.limite_aprovacao,
    'estado', v_conta.estado,
    'pendente_saida', (
      select coalesce(sum(valor), 0) from public.transacoes
      where origem_iban = v_conta.iban and estado = 'pendente'
    )
  ));
exception when others then
  return jsonb_build_object('ok', false, 'erro', 'Falha ao ler saldo: ' || sqlerrm);
end;
$$;

-- ---------------------------------------------------------------------
-- banco_extrato: movimentos da conta, com filtros opcionais.
-- Cada linha diz se foi entrada ou saída do ponto de vista da conta.
-- ---------------------------------------------------------------------
create or replace function public.banco_extrato(
  p_cedula text default null,
  p_estado text default null,
  p_categoria text default null,
  p_limite int default 50
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_cedula text;
  v_iban text;
  v_linhas jsonb;
begin
  if auth.uid() is null then
    return jsonb_build_object('ok', false, 'erro', 'Sem sessão.');
  end if;

  v_cedula := coalesce(p_cedula, public.fn_minha_cedula());
  if v_cedula is null then
    return jsonb_build_object('ok', false, 'erro', 'Sem ficha na Carteirinha.');
  end if;

  if not (
    public.fn_e_professor()
    or v_cedula in (public.fn_minha_cedula(), public.fn_minha_empresa_cedula())
  ) then
    return jsonb_build_object('ok', false, 'erro', 'Sem acesso a esta conta.');
  end if;

  select iban into v_iban from public.contas where cedula = v_cedula;
  if v_iban is null then
    return jsonb_build_object('ok', false, 'erro', 'Esta cédula ainda não tem conta.');
  end if;

  select coalesce(jsonb_agg(linha order by (linha->>'criada_em') desc), '[]'::jsonb)
    into v_linhas
  from (
    select jsonb_build_object(
      'id', t.id,
      'sentido', case when t.origem_iban = v_iban then 'saida' else 'entrada' end,
      'valor', t.valor,
      'categoria', t.categoria,
      'descricao', t.descricao,
      'estado', t.estado,
      'codigo_auth', t.codigo_auth,
      'criada_em', t.criada_em,
      'contraparte', case when t.origem_iban = v_iban then t.destino_iban else coalesce(t.origem_iban, 'emissão') end
    ) as linha
    from public.transacoes t
    where (t.origem_iban = v_iban or t.destino_iban = v_iban)
      and (p_estado is null or t.estado = p_estado)
      and (p_categoria is null or t.categoria = p_categoria)
    order by t.criada_em desc
    limit greatest(coalesce(p_limite, 50), 1)
  ) s;

  return jsonb_build_object('ok', true, 'dados', jsonb_build_object(
    'cedula', v_cedula, 'iban', v_iban, 'movimentos', v_linhas));
exception when others then
  return jsonb_build_object('ok', false, 'erro', 'Falha ao ler extrato: ' || sqlerrm);
end;
$$;

-- ---------------------------------------------------------------------
-- Nomes que a skill define, sobre a lógica única do 0001.
-- ---------------------------------------------------------------------
create or replace function public.banco_aprovar(p_transacao_id uuid)
returns jsonb
language sql
security definer
set search_path = public
as $$ select public.banco_decidir_pendente(p_transacao_id, true); $$;

create or replace function public.banco_rejeitar(p_transacao_id uuid)
returns jsonb
language sql
security definer
set search_path = public
as $$ select public.banco_decidir_pendente(p_transacao_id, false); $$;
