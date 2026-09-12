-- =====================================================================
-- ROW LEVEL SECURITY (RLS) — WAJIB dijalankan setelah schema.sql
-- Tanpa ini, siapa pun dengan anon key bisa baca/tulis semua data.
-- Jalankan di Supabase SQL Editor.
-- =====================================================================

ALTER TABLE users ENABLE ROW LEVEL SECURITY;
ALTER TABLE ruko ENABLE ROW LEVEL SECURITY;
ALTER TABLE units ENABLE ROW LEVEL SECURITY;
ALTER TABLE aset ENABLE ROW LEVEL SECURITY;
ALTER TABLE jadwal_maintenance ENABLE ROW LEVEL SECURITY;
ALTER TABLE sewa ENABLE ROW LEVEL SECURITY;
ALTER TABLE laporan_kerusakan ENABLE ROW LEVEL SECURITY;
ALTER TABLE notifikasi ENABLE ROW LEVEL SECURITY;

-- ---------------------------------------------------------------------
-- Helper: fungsi ambil role user yang sedang login
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION current_user_role()
RETURNS user_role
LANGUAGE sql STABLE
AS $$
  SELECT role FROM users WHERE id = auth.uid();
$$;

CREATE OR REPLACE FUNCTION current_user_owner_scope()
RETURNS UUID
LANGUAGE sql STABLE
AS $$
  -- Jika owner: kembalikan id sendiri. Jika admin: kembalikan id owner yang mendelegasikan.
  SELECT CASE
    WHEN role = 'owner' THEN id
    WHEN role = 'admin' THEN delegated_by_owner_id
    ELSE NULL
  END
  FROM users WHERE id = auth.uid();
$$;

-- ---------------------------------------------------------------------
-- USERS: setiap user bisa lihat profil sendiri; owner bisa lihat admin/tenant
-- yang terkait dengannya (disederhanakan: bisa lihat semua user untuk tahap awal)
-- ---------------------------------------------------------------------
CREATE POLICY "Lihat profil sendiri" ON users
    FOR SELECT USING (id = auth.uid());

CREATE POLICY "Owner lihat admin & tenant miliknya" ON users
    FOR SELECT USING (
        current_user_role() = 'owner' AND delegated_by_owner_id = auth.uid()
    );

CREATE POLICY "Update profil sendiri" ON users
    FOR UPDATE USING (id = auth.uid());

-- ---------------------------------------------------------------------
-- RUKO: hanya owner & admin delegasinya yang bisa akses
-- ---------------------------------------------------------------------
CREATE POLICY "Owner & admin kelola ruko miliknya" ON ruko
    FOR ALL USING (owner_id = current_user_owner_scope());

-- ---------------------------------------------------------------------
-- UNITS: ikut scope ruko; tenant bisa lihat unit yang disewanya sendiri
-- ---------------------------------------------------------------------
CREATE POLICY "Owner & admin kelola units" ON units
    FOR ALL USING (
        ruko_id IN (SELECT id FROM ruko WHERE owner_id = current_user_owner_scope())
    );

CREATE POLICY "Tenant lihat unit yang disewa" ON units
    FOR SELECT USING (
        id IN (SELECT unit_id FROM sewa WHERE tenant_id = auth.uid() AND status = 'aktif')
    );

-- ---------------------------------------------------------------------
-- ASET: owner & admin kelola; admin TIDAK BOLEH hapus (dibatasi lewat
-- policy DELETE terpisah, bukan lewat ALL) dan tidak boleh lihat nilai_beli
-- (dibatasi lewat VIEW terpisah di aplikasi, bukan lewat RLS kolom).
-- Tenant hanya bisa lihat aset di unit yang disewanya.
-- ---------------------------------------------------------------------
CREATE POLICY "Owner & admin lihat/tambah/edit aset" ON aset
    FOR SELECT USING (
        ruko_id IN (SELECT id FROM ruko WHERE owner_id = current_user_owner_scope())
    );

CREATE POLICY "Owner & admin insert aset" ON aset
    FOR INSERT WITH CHECK (
        ruko_id IN (SELECT id FROM ruko WHERE owner_id = current_user_owner_scope())
    );

CREATE POLICY "Owner & admin update aset" ON aset
    FOR UPDATE USING (
        ruko_id IN (SELECT id FROM ruko WHERE owner_id = current_user_owner_scope())
    );

CREATE POLICY "Hanya owner hapus aset" ON aset
    FOR DELETE USING (
        ruko_id IN (SELECT id FROM ruko WHERE owner_id = auth.uid())
        AND current_user_role() = 'owner'
    );

CREATE POLICY "Tenant lihat aset di unit sewaannya" ON aset
    FOR SELECT USING (
        unit_id IN (SELECT unit_id FROM sewa WHERE tenant_id = auth.uid() AND status = 'aktif')
    );

-- ---------------------------------------------------------------------
-- LAPORAN KERUSAKAN
-- ---------------------------------------------------------------------
CREATE POLICY "Tenant buat & lihat laporan sendiri" ON laporan_kerusakan
    FOR ALL USING (tenant_id = auth.uid())
    WITH CHECK (tenant_id = auth.uid());

CREATE POLICY "Owner & admin lihat & proses laporan" ON laporan_kerusakan
    FOR SELECT USING (
        aset_id IN (
            SELECT a.id FROM aset a
            JOIN ruko r ON r.id = a.ruko_id
            WHERE r.owner_id = current_user_owner_scope()
        )
    );

CREATE POLICY "Owner & admin update laporan" ON laporan_kerusakan
    FOR UPDATE USING (
        aset_id IN (
            SELECT a.id FROM aset a
            JOIN ruko r ON r.id = a.ruko_id
            WHERE r.owner_id = current_user_owner_scope()
        )
    );
    -- Catatan: pembatasan "admin tidak boleh menutup laporan (status=selesai)"
    -- sebaiknya tetap divalidasi juga di sisi aplikasi/API, karena RLS
    -- row-level tidak mudah membatasi "boleh update kolom X tapi tidak Y
    -- ke value tertentu" tanpa trigger tambahan.

-- ---------------------------------------------------------------------
-- SEWA & NOTIFIKASI: mengikuti scope yang sama
-- ---------------------------------------------------------------------
CREATE POLICY "Owner & admin kelola sewa" ON sewa
    FOR ALL USING (
        unit_id IN (
            SELECT u.id FROM units u
            JOIN ruko r ON r.id = u.ruko_id
            WHERE r.owner_id = current_user_owner_scope()
        )
    );

CREATE POLICY "Tenant lihat sewa sendiri" ON sewa
    FOR SELECT USING (tenant_id = auth.uid());

CREATE POLICY "User lihat notifikasi sendiri" ON notifikasi
    FOR SELECT USING (user_id = auth.uid());

CREATE POLICY "User tandai notifikasi terbaca" ON notifikasi
    FOR UPDATE USING (user_id = auth.uid());
