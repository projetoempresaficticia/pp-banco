-- pp-banco — 0009 — nomes em vez de cédulas cruas nas listas
--
-- As duas listas de boletos resolviam o nome da contraparte com um
-- `left join public.empresas`. Uma pessoa também emite e recebe faturas
-- — o Professor comprou pão à Padaria Central — e nesses casos o join
-- não encontrava nada e o `coalesce` caía para a cédula: a lista dizia
-- "a cargo de PP-2026-00002" em vez de "a cargo de Professor Prepara".
--
-- Passam a usar `fn_nome_de` (0007), que procura nas duas tabelas.
--
-- Aproveita-se para tapar a fuga de `sqlerrm`: devolver
-- 'Falha ao listar: ' || sqlerrm põe nomes de colunas e de constraints
-- no ecrã de um formando (viola o R1 da pp-base) e não o ajuda em nada.
-- O detalhe fica no log do Postgres.
--
-- NOTA: a mesma fuga existe em mais ~25 funções deste ecossistema, de
-- vários repos. Fica registada aqui; a limpeza é uma passagem própria.

create or replace function public.banco_boletos(p_cedula text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare v_cedula text; v_a_pagar jsonb; v_emitidos jsonb;
begin
  if auth.uid() is null then
    return jsonb_build_object('ok', false, 'erro', 'Sem sessão.');
  end if;
  v_cedula := coalesce(p_cedula, public.fn_minha_empresa_cedula(), public.fn_minha_cedula());
  if v_cedula is null then
    return jsonb_build_object('ok', false, 'erro', 'Sem ficha na Carteirinha.');
  end if;
  if not (public.fn_e_professor() or public.fn_cedula_minha(v_cedula)) then
    return jsonb_build_object('ok', false, 'erro', 'Sem acesso.');
  end if;

  select coalesce(jsonb_agg(l order by (l->>'prazo')), '[]'::jsonb) into v_a_pagar
  from (
    select jsonb_build_object(
      'entidade', b.entidade, 'referencia', b.referencia_mb,
      'linha', b.entidade || ' ' || substr(b.referencia_mb,1,3) || ' ' || substr(b.referencia_mb,4,3) || ' ' || substr(b.referencia_mb,7,3),
      'fatura', f.numero, 'valor', b.valor, 'estado', b.estado,
      'prazo', b.prazo, 'vencido', b.prazo < now() and b.estado = 'por_pagar',
      'descricao', f.descricao, 'fatura_id', f.id,
      'contraparte', public.fn_nome_de(f.emitente_cedula)) as l
    from public.boletos b
    join public.faturas f on f.id = b.fatura_id
    where f.devedor_cedula = v_cedula and b.estado <> 'cancelado'
  ) s;

  select coalesce(jsonb_agg(l order by (l->>'prazo')), '[]'::jsonb) into v_emitidos
  from (
    select jsonb_build_object(
      'entidade', b.entidade, 'referencia', b.referencia_mb,
      'linha', b.entidade || ' ' || substr(b.referencia_mb,1,3) || ' ' || substr(b.referencia_mb,4,3) || ' ' || substr(b.referencia_mb,7,3),
      'fatura', f.numero, 'valor', b.valor, 'estado', b.estado,
      'prazo', b.prazo, 'vencido', b.prazo < now() and b.estado = 'por_pagar',
      'descricao', f.descricao, 'fatura_id', f.id,
      'contraparte', public.fn_nome_de(f.devedor_cedula)) as l
    from public.boletos b
    join public.faturas f on f.id = b.fatura_id
    where f.emitente_cedula = v_cedula
  ) s;

  return jsonb_build_object('ok', true, 'dados', jsonb_build_object(
    'cedula', v_cedula, 'a_pagar', v_a_pagar, 'emitidos', v_emitidos));
exception when others then
  return jsonb_build_object('ok', false, 'erro', 'Não foi possível listar os boletos.');
end;
$$;

create or replace function public.banco_boletos_por_pagar(p_cedula text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare v_cedula text; v_linhas jsonb;
begin
  if auth.uid() is null then
    return jsonb_build_object('ok', false, 'erro', 'Sem sessão.');
  end if;
  v_cedula := coalesce(p_cedula, public.fn_minha_empresa_cedula(), public.fn_minha_cedula());
  if v_cedula is null then
    return jsonb_build_object('ok', false, 'erro', 'Sem ficha na Carteirinha.');
  end if;
  if not (public.fn_e_professor() or public.fn_cedula_minha(v_cedula)) then
    return jsonb_build_object('ok', false, 'erro', 'Sem acesso.');
  end if;
  select coalesce(jsonb_agg(l order by l->>'prazo'), '[]'::jsonb) into v_linhas
  from (
    select jsonb_build_object(
      'referencia', b.referencia, 'fatura', f.numero, 'valor', b.valor,
      'estado', b.estado, 'prazo', b.prazo, 'atrasado', b.prazo < now(),
      'descricao', f.descricao, 'emitente', f.emitente_cedula,
      'emitente_nome', public.fn_nome_de(f.emitente_cedula)) as l
    from public.boletos b
    join public.faturas f on f.id = b.fatura_id
    where f.devedor_cedula = v_cedula
      and b.estado in ('por_pagar', 'em_pagamento')
      and f.estado <> 'anulada'
  ) s;
  return jsonb_build_object('ok', true, 'dados', jsonb_build_object(
    'cedula', v_cedula, 'boletos', v_linhas));
exception when others then
  return jsonb_build_object('ok', false, 'erro', 'Não foi possível listar os boletos por pagar.');
end;
$$;
