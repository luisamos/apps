$server = "DELL"
$database = "BDPDU"
$outDir = "C:\Users\luisa\Downloads\MPE"

if (!(Test-Path $outDir)) {
    New-Item -ItemType Directory -Path $outDir | Out-Null
}

$tables = sqlcmd -S $server -d $database -E -h -1 -W -Q @"
SET NOCOUNT ON;
SELECT s.name + '.' + t.name
FROM sys.tables t
INNER JOIN sys.schemas s ON t.schema_id = s.schema_id
INNER JOIN sys.columns c ON t.object_id = c.object_id
INNER JOIN sys.types ty ON c.user_type_id = ty.user_type_id
WHERE ty.name IN ('geometry', 'geography')
GROUP BY s.name, t.name
ORDER BY s.name, t.name;
"@

$conn = "MSSQL:server=$server;database=$database;trusted_connection=yes"

foreach ($fullTable in $tables) {

    if ([string]::IsNullOrWhiteSpace($fullTable)) { continue }

    $safeName = $fullTable.Replace('.', '_')
    $outShp = Join-Path $outDir "$safeName.shp"

    ogr2ogr `
      -overwrite `
      -f "ESRI Shapefile" `
      -a_srs EPSG:32719 `
      -lco ENCODING=UTF-8 `
      $outShp `
      $conn `
      $fullTable

    Write-Host "Exportado: $fullTable"
}


$outGpkg = "C:\Users\luisa\Downloads\MPE\$database.gpkg"

foreach ($fullTable in $tables) {
    if ([string]::IsNullOrWhiteSpace($fullTable)) { continue }

    ogr2ogr `
      -f GPKG `
      $outGpkg `
      $conn `
      $fullTable `
      -append `
      -nln $fullTable `
      -a_srs EPSG:32719

    Write-Host "Exportado: $fullTable"
}