# Returns an attrset of derivations, one per migration step (N -> N+1).
# Each checks that applying upgrade-(N+1).sql to schema version N
# produces the same schema as a fresh load of schema version N+1.
{
  lib,
  stdenv,
  postgresql_17,
  pg-schema-diff,
}:

let
  # unwrapped
  cpp = "${stdenv.cc.cc}/bin/cpp";

  # Extract version numbers from each source
  migrationVersions = map (
    name: lib.toInt (lib.removePrefix "upgrade-" (lib.removeSuffix ".sql" name))
  ) (builtins.attrNames (builtins.readDir ./migrations));

  schemaVersions = map (name: lib.toInt (lib.removePrefix "hydra-" (lib.removeSuffix ".sql" name))) (
    builtins.filter (name: lib.hasSuffix ".sql" name) (builtins.attrNames (builtins.readDir ./schemas))
  );

  allVersions = lib.unique (migrationVersions ++ schemaVersions);

  maxMigrationVersion = lib.last (lib.sort lib.lessThan migrationVersions);

  # A version N is covered when we have schema N-1, schema N, and upgrade-N.sql.
  # Schema-only versions (like version 1, the base) are also covered.
  # The highest migration version is special: it uses hydra.sql (the current
  # schema) as its target, so it doesn't need a vendored schema file.
  isCovered =
    n:
    (
      builtins.elem n migrationVersions
      && builtins.elem (n - 1) schemaVersions
      && (builtins.elem n schemaVersions || n == maxMigrationVersion)
    )
    || (!builtins.elem n migrationVersions && builtins.elem n schemaVersions);

  partitioned = lib.partition isCovered allVersions;
in
assert
  partitioned.wrong == [ ]
  || throw "Missing schemas or migrations for versions: ${toString partitioned.wrong}";

builtins.listToAttrs (
  map (
    to:
    let
      from = to - 1;
      schemaBefore = ./schemas/hydra-${toString from}.sql;
      # The latest migration tests against the current schema directly,
      # so we don't need to vendor a copy of it.
      schemaAfter = if to == maxMigrationVersion then ./hydra.sql else ./schemas/hydra-${toString to}.sql;
      migration = ./migrations/upgrade-${toString to}.sql;
    in
    {
      name = "migration-${toString from}-to-${toString to}";
      value = stdenv.mkDerivation {
        name = "check-migration-${toString from}-to-${toString to}";

        dontUnpack = true;

        nativeBuildInputs = [
          postgresql_17
          pg-schema-diff
        ];

        buildPhase = ''
          # Preprocess schema to resolve #ifdef POSTGRESQL / #ifdef SQLITE
          ${cpp} -DPOSTGRESQL -P -undef -nostdinc \
            -traditional-cpp \
            ${schemaBefore} -o "$TMPDIR/schema-before.sql"
          ${cpp} -DPOSTGRESQL -P -undef -nostdinc \
            -traditional-cpp \
            ${schemaAfter} -o "$TMPDIR/schema-after.sql"

          # Put the target schema in a directory for pg-schema-diff
          mkdir -p "$TMPDIR/target-schema"
          cp "$TMPDIR/schema-after.sql" "$TMPDIR/target-schema/"

          export PGDATA="$TMPDIR/pgdata"
          export PGHOST="$TMPDIR/socket"
          mkdir -p "$PGHOST"

          initdb -D "$PGDATA" --no-locale -E UTF8
          pg_ctl -D "$PGDATA" -o "-F -h \"\" -k $PGHOST" -w start

          trap 'pg_ctl -D "$PGDATA" -w stop -m immediate' EXIT

          # --- Build migrated schema ---
          cp ${migration} "$TMPDIR/migration.sql"
        ''
        # Fixup for PG 17 auto-generated constraint names
        # (older PG used numeric suffixes like _fkey2; PG 17 uses column names)
        + lib.optionalString (to == 67) ''
          sed -i \
            -e 's/builds_project_fkey2/builds_project_jobset_job_fkey/g' \
            -e 's/buildmetrics_project_fkey2/buildmetrics_project_jobset_job_fkey/g' \
            -e 's/starredjobs_project_fkey2/starredjobs_project_jobset_job_fkey/g' \
            "$TMPDIR/migration.sql"
        ''
        + ''

          createdb -h "$PGHOST" migrated
          psql -h "$PGHOST" --set ON_ERROR_STOP=1 -f "$TMPDIR/schema-before.sql" migrated
          psql -h "$PGHOST" --set ON_ERROR_STOP=1 -f "$TMPDIR/migration.sql" migrated

          # --- Compare migrated DB against fresh target schema ---
          if ! pg-schema-diff plan \
            --from-dsn "postgresql:///migrated?host=$PGHOST" \
            --to-dir "$TMPDIR/target-schema"; then
            echo ""
            echo "Migration ${toString from} -> ${toString to} produces a different schema than schemas/hydra-${toString to}.sql"
            exit 1
          fi

          echo "Migration ${toString from} -> ${toString to}: OK"
        '';

        installPhase = ''
          touch $out
        '';

        meta.description = "Check migration from schema version ${toString from} to ${toString to}";
      };
    }
  ) (builtins.filter (n: builtins.elem n migrationVersions) partitioned.right)
)
// {
  migration-86-to-88-populated = stdenv.mkDerivation {
    name = "check-migration-86-to-88-populated";
    dontUnpack = true;
    nativeBuildInputs = [ postgresql_17 ];
    buildPhase = ''
      ${cpp} -DPOSTGRESQL -P -undef -nostdinc -traditional-cpp \
        ${./schemas/hydra-86.sql} -o "$TMPDIR/schema.sql"
      export PGDATA="$TMPDIR/pgdata"
      export PGHOST="$TMPDIR/socket"
      mkdir -p "$PGHOST"
      initdb -D "$PGDATA" --no-locale -E UTF8
      pg_ctl -D "$PGDATA" -o "-F -h \"\" -k $PGHOST" -w start
      trap 'pg_ctl -D "$PGDATA" -w stop -m immediate' EXIT
      createdb populated
      psql --set ON_ERROR_STOP=1 -f "$TMPDIR/schema.sql" populated
      psql --set ON_ERROR_STOP=1 populated <<'SQL'
      INSERT INTO Users(username,emailaddress,password) VALUES ('test','test@invalid','unused');
      INSERT INTO Projects(name,displayname,owner) VALUES ('test','Test','test');
      INSERT INTO Jobsets(id,project,name,emailoverride,type,flake,starttime)
        VALUES (1,'test','test','test@invalid',1,'path:/test',2147483647);
      INSERT INTO Builds(id,finished,timestamp,jobset_id,job,drvpath,system,starttime,stoptime,buildstatus)
        VALUES (1,1,2147483647,1,'test','/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-test.drv','x86_64-linux',2147483647,2147483647,0);
      INSERT INTO BuildSteps(build,stepnr,type,busy,drvpath,status,starttime,stoptime)
        VALUES (1,1,0,0,'/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-test.drv',0,2147483647,2147483647);
      INSERT INTO BuildStepOutputs(build,stepnr,name,path)
        VALUES (1,1,'out','/nix/store/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb-output');
      INSERT INTO TaskRetries(channel,pluginname,payload,attempts,retry_at)
        VALUES ('build_finished','Hydra::Plugin::S3Backup','1',1,2147483647);
      SQL

      # The old runner already wrote status=13 without persisting its
      # resolved drv. The real migration must reject that unsupported state.
      createdb --template=populated old_resolved
      psql --set ON_ERROR_STOP=1 old_resolved -c "UPDATE BuildSteps SET status=13"
      if psql --single-transaction --set ON_ERROR_STOP=1 \
          -f ${./migrations/upgrade-87.sql} old_resolved > "$TMPDIR/expected-failure.log" 2>&1; then
        echo "Migration unexpectedly accepted an old resolution without its drv mapping"
        exit 1
      fi
      case "$(cat "$TMPDIR/expected-failure.log")" in
        *buildsteps_resolved_consistent*) ;;
        *) cat "$TMPDIR/expected-failure.log"; exit 1 ;;
      esac

      psql --set ON_ERROR_STOP=1 -f ${./migrations/upgrade-87.sql} populated
      # A resolution recorded by the new schema is supported by migration 88.
      psql --set ON_ERROR_STOP=1 populated -c "INSERT INTO BuildSteps(build,stepnr,type,busy,drvpath,status,resolveddrvpath) VALUES (1,2,0,0,'/nix/store/cccccccccccccccccccccccccccccccc-ca.drv',13,'dddddddddddddddddddddddddddddddd-resolved.drv')"
      psql --set ON_ERROR_STOP=1 -f ${./migrations/upgrade-88.sql} populated
      psql --set ON_ERROR_STOP=1 populated <<'SQL'
      DO $$ BEGIN
        IF (SELECT timestamp FROM Builds WHERE id=1) <> 2147483647
          OR (SELECT retry_at FROM TaskRetries LIMIT 1) <> 2147483647
          OR (SELECT path FROM BuildStepOutputs WHERE build=1 AND stepnr=1) <> '/nix/store/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb-output'
          OR (SELECT resolveddrvpath FROM BuildSteps WHERE build=1 AND stepnr=2) <> 'dddddddddddddddddddddddddddddddd-resolved.drv'
        THEN RAISE EXCEPTION 'migration changed existing data'; END IF;
      END $$;
      UPDATE Builds SET timestamp=4294967296,starttime=4294967296,stoptime=4294967296 WHERE id=1;
      UPDATE BuildSteps SET starttime=4294967296,stoptime=4294967296;
      UPDATE Jobsets SET starttime=4294967296;
      UPDATE TaskRetries SET retry_at=4294967296;
      DO $$ BEGIN
        IF (SELECT timestamp FROM Builds WHERE id=1) <> 4294967296
          OR (SELECT starttime FROM BuildSteps WHERE build=1 AND stepnr=1) <> 4294967296
          OR (SELECT starttime FROM Jobsets WHERE id=1) <> 4294967296
          OR (SELECT retry_at FROM TaskRetries LIMIT 1) <> 4294967296
        THEN RAISE EXCEPTION '64-bit timestamps were not preserved'; END IF;
      END $$;
      SQL
    '';
    installPhase = "touch $out";
    meta.description = "Check populated Hydra schema migrations, old CA blockers and 64-bit timestamps";
  };
}
