--
-- FECHA CREACIÓN		    : 01-02-2026
-- FECHA DE MODIFICACIÓN: 19-03-2026
--

-- 1. Crear usuario
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_roles WHERE rolname = 'kaypacha'
    ) THEN
        CREATE USER kaypacha WITH PASSWORD '123';
    END IF;
END
$$;

-- 2. Permitir conexión a la base de datos
GRANT CONNECT ON DATABASE mdw TO kaypacha;

-- 3. Permitir acceso a los esquemas
GRANT USAGE ON SCHEMA geo TO kaypacha;
GRANT USAGE ON SCHEMA catastro TO kaypacha;

-- 4. Permisos de lectura sobre todas las tablas existentes
GRANT SELECT ON ALL TABLES IN SCHEMA geo TO kaypacha;
GRANT SELECT ON ALL TABLES IN SCHEMA catastro TO kaypacha;

-- 5. Permisos sobre secuencias
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA geo TO kaypacha;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA catastro TO kaypacha;

-- 6. Permisos por defecto para tablas futuras
ALTER DEFAULT PRIVILEGES IN SCHEMA geo
GRANT SELECT ON TABLES TO kaypacha;

ALTER DEFAULT PRIVILEGES IN SCHEMA catastro
GRANT SELECT ON TABLES TO kaypacha;

-- 7. Permisos por defecto para secuencias futuras
ALTER DEFAULT PRIVILEGES IN SCHEMA geo
GRANT USAGE, SELECT ON SEQUENCES TO kaypacha;

ALTER DEFAULT PRIVILEGES IN SCHEMA catastro
GRANT USAGE, SELECT ON SEQUENCES TO kaypacha;

-- 8. Definir search_path
ALTER ROLE kaypacha SET search_path TO geo, catastro, public;