-- ============================================================
-- Esquema do banco de dados — Perfil de Sondagem (SaaS)
-- Cole este arquivo inteiro no SQL Editor do Supabase e clique em "Run".
-- ============================================================

-- ---------- extensão para gerar IDs únicos ----------
create extension if not exists "pgcrypto";

-- ---------- tabela: empresas (organizations) ----------
-- Cada empresa cliente (ex.: Soiltec) é uma linha aqui.
create table if not exists organizations (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  logo_data_uri text,           -- logo da empresa em base64, pro cabeçalho/carimbo impresso
  created_at timestamptz not null default now()
);

-- ---------- tabela: perfis de usuário (profiles) ----------
-- Estende a tabela de autenticação do Supabase (auth.users) com o vínculo
-- de cada pessoa a uma empresa e seu papel dentro dela.
create table if not exists profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  organization_id uuid references organizations(id) on delete set null,
  full_name text,
  role text not null default 'tecnico' check (role in ('admin','tecnico')),
  created_at timestamptz not null default now()
);

-- Cria automaticamente um "profile" vazio (sem empresa ainda) toda vez que
-- alguém se cadastra. A empresa é vinculada depois (ver observação no final).
create or replace function public.handle_new_user()
returns trigger as $$
begin
  insert into public.profiles (id, full_name)
  values (new.id, coalesce(new.raw_user_meta_data->>'full_name', ''));
  return new;
end;
$$ language plpgsql security definer;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute procedure public.handle_new_user();

-- ---------- tabela: sondagens ----------
-- Cada sondagem salva fica aqui como um único registro. Os dados do
-- formulário inteiro (idêntico ao que collectState() já monta no app) vão
-- no campo "data" (jsonb) — não precisamos recriar cada campo como coluna.
-- Só puxamos pra fora as colunas que a lista lateral e a busca precisam.
create table if not exists sondagens (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id) on delete cascade,
  created_by uuid references profiles(id) on delete set null,
  sondagem_no text,
  poco_no text,
  obra text,
  data jsonb not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists sondagens_org_idx on sondagens(organization_id);

-- mantém "updated_at" sempre atual a cada edição
create or replace function public.set_updated_at()
returns trigger as $$
begin
  new.updated_at = now();
  return new;
end;
$$ language plpgsql;

drop trigger if exists sondagens_set_updated_at on sondagens;
create trigger sondagens_set_updated_at
  before update on sondagens
  for each row execute procedure public.set_updated_at();

-- ============================================================
-- Segurança: cada empresa só enxerga os próprios dados (RLS)
-- ============================================================

-- Função auxiliar que devolve a empresa (organization_id) do usuário logado.
-- É "security definer" de propósito: ela roda ignorando o RLS da tabela
-- profiles, então pode ser usada DENTRO das próprias políticas de profiles
-- sem cair em recursão infinita (uma política de profiles que consultasse
-- profiles de novo, sujeita à mesma política, trava o Postgres).
create or replace function public.current_org_id()
returns uuid
language sql
security definer
set search_path = public
stable
as $$
  select organization_id from profiles where id = auth.uid();
$$;

alter table organizations enable row level security;
alter table profiles enable row level security;
alter table sondagens enable row level security;

-- organizations: só vê a própria empresa
create policy "ver própria empresa" on organizations
  for select using (id = current_org_id());

-- profiles: vê o próprio perfil e os colegas da mesma empresa
create policy "ver próprio perfil" on profiles
  for select using (id = auth.uid());

create policy "ver perfis da mesma empresa" on profiles
  for select using (
    organization_id is not null and organization_id = current_org_id()
  );

create policy "atualizar próprio perfil" on profiles
  for update using (id = auth.uid());

-- sondagens: só vê/edita/apaga sondagens da própria empresa
create policy "ver sondagens da empresa" on sondagens
  for select using (organization_id = current_org_id());

create policy "criar sondagem na própria empresa" on sondagens
  for insert with check (organization_id = current_org_id());

create policy "editar sondagens da empresa" on sondagens
  for update using (organization_id = current_org_id());

create policy "apagar sondagens da empresa" on sondagens
  for delete using (organization_id = current_org_id());

-- ============================================================
-- Armazenamento das fotos do local de cada sondagem (Supabase Storage)
-- ============================================================
-- Cria o "bucket" (uma pasta de armazenamento dentro do Supabase) onde
-- ficam as fotos. É privado (public=false) — ninguém acessa uma foto só
-- por adivinhar o link; só quem está logado e é da empresa dona da foto,
-- através das políticas abaixo.
insert into storage.buckets (id, name, public)
values ('fotos-sondagem', 'fotos-sondagem', false)
on conflict (id) do nothing;

-- Cada foto é salva num caminho assim: "<id da empresa>/<id da sondagem>/foto-local.jpg".
-- Então basta conferir se o primeiro "pedaço" desse caminho (a pasta) é a
-- mesma empresa do usuário logado — a mesma ideia usada nas tabelas acima,
-- só que aplicada aos arquivos em vez de linhas de tabela.
create policy "ver fotos da propria empresa" on storage.objects
  for select using (
    bucket_id = 'fotos-sondagem'
    and (storage.foldername(name))[1] = current_org_id()::text
  );

create policy "enviar fotos para a propria empresa" on storage.objects
  for insert with check (
    bucket_id = 'fotos-sondagem'
    and (storage.foldername(name))[1] = current_org_id()::text
  );

create policy "atualizar fotos da propria empresa" on storage.objects
  for update using (
    bucket_id = 'fotos-sondagem'
    and (storage.foldername(name))[1] = current_org_id()::text
  );

create policy "apagar fotos da propria empresa" on storage.objects
  for delete using (
    bucket_id = 'fotos-sondagem'
    and (storage.foldername(name))[1] = current_org_id()::text
  );

-- ============================================================
-- OBSERVAÇÃO IMPORTANTE (leia antes de testar):
-- Quando alguém se cadastra, o "profile" é criado SEM empresa (organization_id
-- fica nulo) — por isso, até essa pessoa ser vinculada a uma empresa, ela não
-- enxerga nenhuma sondagem (a política de RLS exige organization_id).
--
-- Para o MVP com poucas empresas piloto, o jeito mais simples é você mesmo
-- vincular manualmente pelo painel do Supabase, depois que a pessoa se
-- cadastrar:
--   1. Table Editor > organizations > Insert row > preencha "name" com o
--      nome da empresa (ex.: "Soiltec Soluções Ambientais") > Save.
--      Copie o "id" gerado.
--   2. Table Editor > profiles > ache a linha da pessoa (pelo id, que é o
--      mesmo da tabela auth.users > Authentication) > cole esse "id" no
--      campo organization_id > Save.
-- Isso é manual de propósito no início — um fluxo de "criar empresa" e
-- "convidar colega" automático é coisa pra quando já tiver validado o
-- produto com essas primeiras empresas.
-- ============================================================
