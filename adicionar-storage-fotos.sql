-- ============================================================
-- ATUALIZAÇÃO do banco: armazenamento das fotos do local da sondagem
-- ============================================================
-- Rafael, cole SÓ este arquivo (não o schema.sql inteiro de novo) no SQL
-- Editor do Supabase e clique em "Run". Ele soma ao que você já criou antes
-- — não mexe nas tabelas nem nos dados que já existem.
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
-- mesma empresa do usuário logado — a mesma ideia já usada nas tabelas
-- "organizations", "profiles" e "sondagens", só que aplicada a arquivos.
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
