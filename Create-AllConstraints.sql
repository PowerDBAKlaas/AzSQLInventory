-- Run on source DB
-- Excludes FileTables; generates constraints to apply on IntermediateDB

DECLARE @TargetDB sysname = N'IntermediateDB';
DECLARE @sql nvarchar(max) = N'';

-- ── DEFAULT CONSTRAINTS ────────────────────────────────────────────────
SELECT @sql += N'ALTER TABLE ' + QUOTENAME(SCHEMA_NAME(t.schema_id)) + N'.' + QUOTENAME(t.name)
    + N' ADD CONSTRAINT ' + QUOTENAME(dc.name)
    + N' DEFAULT ' + dc.definition
    + N' FOR ' + QUOTENAME(c.name) + N';' + CHAR(13)
FROM sys.default_constraints dc
JOIN sys.tables t  ON dc.parent_object_id = t.object_id
JOIN sys.columns c ON dc.parent_object_id = c.object_id AND dc.parent_column_id = c.column_id
WHERE t.is_filetable = 0
ORDER BY t.name, c.name;

-- ── CHECK CONSTRAINTS ──────────────────────────────────────────────────
SELECT @sql += N'ALTER TABLE ' + QUOTENAME(SCHEMA_NAME(t.schema_id)) + N'.' + QUOTENAME(t.name)
    + N' ADD CONSTRAINT ' + QUOTENAME(cc.name)
    + N' CHECK ' + cc.definition + N';' + CHAR(13)
FROM sys.check_constraints cc
JOIN sys.tables t ON cc.parent_object_id = t.object_id
WHERE t.is_filetable = 0
ORDER BY t.name;

-- ── FOREIGN KEYS ───────────────────────────────────────────────────────
SELECT @sql += N'ALTER TABLE ' + QUOTENAME(SCHEMA_NAME(pt.schema_id)) + N'.' + QUOTENAME(pt.name)
    + N' ADD CONSTRAINT ' + QUOTENAME(fk.name)
    + N' FOREIGN KEY (' 
    + STRING_AGG(QUOTENAME(pc.name), N', ') WITHIN GROUP (ORDER BY fkc.constraint_column_id)
    + N') REFERENCES '
    + QUOTENAME(SCHEMA_NAME(rt.schema_id)) + N'.' + QUOTENAME(rt.name)
    + N' (' 
    + STRING_AGG(QUOTENAME(rc.name), N', ') WITHIN GROUP (ORDER BY fkc.constraint_column_id)
    + N')'
    + CASE fk.delete_referential_action WHEN 1 THEN N' ON DELETE CASCADE'
                                        WHEN 2 THEN N' ON DELETE SET NULL'
                                        WHEN 3 THEN N' ON DELETE SET DEFAULT' ELSE N'' END
    + CASE fk.update_referential_action WHEN 1 THEN N' ON UPDATE CASCADE'
                                        WHEN 2 THEN N' ON UPDATE SET NULL'
                                        WHEN 3 THEN N' ON UPDATE SET DEFAULT' ELSE N'' END
    + CASE fk.is_not_trusted WHEN 0 THEN N'' ELSE N' WITH NOCHECK' END
    + N';' + CHAR(13)
FROM sys.foreign_keys fk
JOIN sys.foreign_key_columns fkc ON fk.object_id = fkc.constraint_object_id
JOIN sys.tables  pt ON fk.parent_object_id  = pt.object_id
JOIN sys.tables  rt ON fk.referenced_object_id = rt.object_id
JOIN sys.columns pc ON fkc.parent_object_id      = pc.object_id AND fkc.parent_column_id      = pc.column_id
JOIN sys.columns rc ON fkc.referenced_object_id  = rc.object_id AND fkc.referenced_column_id  = rc.column_id
WHERE pt.is_filetable = 0 AND rt.is_filetable = 0
GROUP BY fk.name, fk.delete_referential_action, fk.update_referential_action,
         fk.is_not_trusted, pt.schema_id, pt.name, rt.schema_id, rt.name
ORDER BY pt.name, fk.name;

-- ── OUTPUT ─────────────────────────────────────────────────────────────
PRINT @sql;
-- Or to review first:
-- SELECT @sql;
