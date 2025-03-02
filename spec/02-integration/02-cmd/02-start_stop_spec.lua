local helpers = require "spec.helpers"


for _, strategy in helpers.each_strategy() do

describe("kong start/stop #" .. strategy, function()
  lazy_setup(function()
    helpers.get_db_utils(nil, {
      "routes",
      "services",
    }) -- runs migrations
    helpers.prepare_prefix()
  end)
  after_each(function()
    helpers.kill_all()
  end)
  lazy_teardown(function()
    helpers.clean_prefix()
  end)

  it("fails with referenced values that are not initialized", function()
    local ok, stderr, stdout = helpers.kong_exec("start", {
      prefix = helpers.test_conf.prefix,
      database = strategy,
      nginx_proxy_real_ip_header = "{vault://env/ipheader}",
      pg_database = helpers.test_conf.pg_database,
      cassandra_keyspace = helpers.test_conf.cassandra_keyspace,
      vaults = "env",
    })

    assert.matches("Error: failed to dereference '{vault://env/ipheader}': unable to load value (ipheader) from vault (env): not found [{vault://env/ipheader}] for config option 'nginx_proxy_real_ip_header'", stderr, nil, true)
    assert.is_nil(stdout)
    assert.is_false(ok)

    helpers.clean_logfile()
  end)

  it("fails to read referenced secrets when vault does not exist", function()
    local ok, stderr, stdout = helpers.kong_exec("start", {
      prefix = helpers.test_conf.prefix,
      database = helpers.test_conf.database,
      pg_password = "{vault://non-existent/pg_password}",
      pg_database = helpers.test_conf.pg_database,
      cassandra_keyspace = helpers.test_conf.cassandra_keyspace,
    })
    assert.matches("failed to dereference '{vault://non-existent/pg_password}': vault not found (non-existent)", stderr, nil, true)
    assert.is_nil(stdout)
    assert.is_false(ok)

    helpers.clean_logfile()
  end)

  it("resolves referenced secrets", function()
    helpers.setenv("PG_PASSWORD", "dummy")
    local _, stderr, stdout = assert(helpers.kong_exec("start", {
      prefix = helpers.test_conf.prefix,
      database = helpers.test_conf.database,
      pg_password = "{vault://env/pg_password}",
      pg_database = helpers.test_conf.pg_database,
      cassandra_keyspace = helpers.test_conf.cassandra_keyspace,
      vaults = "env",
    }))
    assert.not_matches("failed to dereference {vault://env/pg_password}", stderr, nil, true)
    assert.matches("Kong started", stdout, nil, true)
    assert(helpers.kong_exec("stop", {
      prefix = helpers.test_conf.prefix,
    }))

    helpers.clean_logfile()
  end)

  it("start help", function()
    local _, stderr = helpers.kong_exec "start --help"
    assert.not_equal("", stderr)
  end)
  it("stop help", function()
    local _, stderr = helpers.kong_exec "stop --help"
    assert.not_equal("", stderr)
  end)
  it("start/stop gracefully with default conf/prefix", function()
    assert(helpers.kong_exec("start", {
      prefix = helpers.test_conf.prefix,
      database = helpers.test_conf.database,
      pg_database = helpers.test_conf.pg_database,
      cassandra_keyspace = helpers.test_conf.cassandra_keyspace
    }))
    assert(helpers.kong_exec("stop", {
      prefix = helpers.test_conf.prefix,
    }))
  end)
  it("start/stop custom Kong conf/prefix", function()
    assert(helpers.kong_exec("start --conf " .. helpers.test_conf_path))
    assert(helpers.kong_exec("stop --prefix " .. helpers.test_conf.prefix))
  end)
  it("stop honors custom Kong prefix higher than environment variable", function()
    assert(helpers.kong_exec("start --conf " .. helpers.test_conf_path))
    helpers.setenv("KONG_PREFIX", "/tmp/dne")
    finally(function() helpers.unsetenv("KONG_PREFIX") end)
    assert(helpers.kong_exec("stop --prefix " .. helpers.test_conf.prefix))
  end)
  it("start/stop Kong with only stream listeners enabled", function()
    assert(helpers.kong_exec("start ", {
      prefix = helpers.test_conf.prefix,
      admin_listen = "off",
      proxy_listen = "off",
      stream_listen = "127.0.0.1:9022",
    }))
    assert(helpers.kong_exec("stop", {
      prefix = helpers.test_conf.prefix
    }))
  end)
  it("start dumps Kong config in prefix", function()
    assert(helpers.kong_exec("start --conf " .. helpers.test_conf_path))
    assert.truthy(helpers.path.exists(helpers.test_conf.kong_env))
  end)
  if strategy == "cassandra" then
    it("should not add [emerg], [alert], [crit], or [error] lines to error log", function()
      assert(helpers.kong_exec("start ", {
        prefix = helpers.test_conf.prefix,
        stream_listen = "127.0.0.1:9022",
        status_listen = "0.0.0.0:8100",
      }))
      assert(helpers.kong_exec("stop", {
        prefix = helpers.test_conf.prefix
      }))

      assert.logfile().has.no.line("[emerg]", true)
      assert.logfile().has.no.line("[alert]", true)
      assert.logfile().has.no.line("[crit]", true)
      assert.logfile().has.no.line("[error]", true)
    end)
  else
    it("should not add [emerg], [alert], [crit], [error] or [warn] lines to error log", function()
      assert(helpers.kong_exec("start ", {
        prefix = helpers.test_conf.prefix,
        stream_listen = "127.0.0.1:9022",
        status_listen = "0.0.0.0:8100",
      }))
      assert(helpers.kong_exec("stop", {
        prefix = helpers.test_conf.prefix
      }))

      assert.logfile().has.no.line("[emerg]", true)
      assert.logfile().has.no.line("[alert]", true)
      assert.logfile().has.no.line("[crit]", true)
      assert.logfile().has.no.line("[error]", true)
      assert.logfile().has.no.line("[warn]", true)
    end)
  end

  if strategy == "cassandra" then
    it("start resolves cassandra contact points", function()
      assert(helpers.kong_exec("start", {
        prefix = helpers.test_conf.prefix,
        database = strategy,
        cassandra_contact_points = "localhost",
        cassandra_keyspace = helpers.test_conf.cassandra_keyspace,
      }))
      assert(helpers.kong_exec("stop", {
        prefix = helpers.test_conf.prefix,
      }))
    end)
  end

  it("creates prefix directory if it doesn't exist", function()
    finally(function()
      helpers.kill_all("foobar")
      pcall(helpers.dir.rmtree, "foobar")
    end)

    assert.falsy(helpers.path.exists("foobar"))
    assert(helpers.kong_exec("start --prefix foobar", {
      pg_database = helpers.test_conf.pg_database,
      cassandra_keyspace = helpers.test_conf.cassandra_keyspace,
    }))
    assert.truthy(helpers.path.exists("foobar"))
  end)

  describe("verbose args", function()
    it("accepts verbose --v", function()
      local _, _, stdout = assert(helpers.kong_exec("start --v --conf " .. helpers.test_conf_path))
      assert.matches("[verbose] prefix in use: ", stdout, nil, true)
    end)
    it("accepts debug --vv", function()
      local _, _, stdout = assert(helpers.kong_exec("start --vv --conf " .. helpers.test_conf_path))
      assert.matches("[verbose] prefix in use: ", stdout, nil, true)
      assert.matches("[debug] prefix = ", stdout, nil, true)
      assert.matches("[debug] database = ", stdout, nil, true)
    end)
    it("prints ENV variables when detected #postgres", function()
      local _, _, stdout = assert(helpers.kong_exec("start --vv --conf " .. helpers.test_conf_path, {
        database = "postgres",
        admin_listen = "127.0.0.1:8001"
      }))
      assert.matches('KONG_DATABASE ENV found with "postgres"', stdout, nil, true)
      assert.matches('KONG_ADMIN_LISTEN ENV found with "127.0.0.1:8001"', stdout, nil, true)
    end)
    it("prints config in alphabetical order", function()
      local _, _, stdout = assert(helpers.kong_exec("start --vv --conf " .. helpers.test_conf_path))
      assert.matches("admin_listen.*anonymous_reports.*cassandra_ssl.*prefix.*", stdout)
    end)
    it("does not print sensitive settings in config", function()
      local _, _, stdout = assert(helpers.kong_exec("start --vv --conf " .. helpers.test_conf_path, {
        pg_password = "do not print",
        cassandra_password = "do not print",
      }))
      assert.matches('KONG_PG_PASSWORD ENV found with "******"', stdout, nil, true)
      assert.matches('KONG_CASSANDRA_PASSWORD ENV found with "******"', stdout, nil, true)
      assert.matches('pg_password = "******"', stdout, nil, true)
      assert.matches('cassandra_password = "******"', stdout, nil, true)
    end)
  end)

  describe("custom --nginx-conf", function()
    local templ_fixture = "spec/fixtures/custom_nginx.template"

    it("accept a custom Nginx configuration", function()
      assert(helpers.kong_exec("start --conf " .. helpers.test_conf_path .. " --nginx-conf " .. templ_fixture))
      assert.truthy(helpers.path.exists(helpers.test_conf.nginx_conf))

      local contents = helpers.file.read(helpers.test_conf.nginx_conf)
      assert.matches("# This is a custom nginx configuration template for Kong specs", contents, nil, true)
      assert.matches("daemon on;", contents, nil, true)
    end)
  end)

  describe("/etc/hosts resolving in CLI", function()
    it("resolves #cassandra hostname", function()
      assert(helpers.kong_exec("start --vv --run-migrations --conf " .. helpers.test_conf_path, {
        cassandra_contact_points = "localhost",
        database = "cassandra"
      }))
    end)
    it("resolves #postgres hostname", function()
      assert(helpers.kong_exec("start --conf " .. helpers.test_conf_path, {
        pg_host = "localhost",
        database = "postgres"
      }))
    end)
  end)

  -- TODO: update with new error messages and behavior
  pending("--run-migrations", function()
    before_each(function()
      helpers.dao:drop_schema()
    end)
    after_each(function()
      helpers.dao:drop_schema()
      helpers.dao:run_migrations()
    end)

    describe("errors", function()
      it("does not start with an empty datastore", function()
        local ok, stderr  = helpers.kong_exec("start --conf "..helpers.test_conf_path)
        assert.False(ok)
        assert.matches("the current database schema does not match this version of Kong.", stderr)
      end)
      it("does not start if migrations are not up to date", function()
        helpers.dao:run_migrations()
        -- Delete a migration to simulate inconsistencies between version
        local _, err = helpers.dao.db:query([[
          DELETE FROM schema_migrations WHERE id='rate-limiting'
        ]])
        assert.is_nil(err)

        local ok, stderr  = helpers.kong_exec("start --conf "..helpers.test_conf_path)
        assert.False(ok)
        assert.matches("the current database schema does not match this version of Kong.", stderr)
      end)
      it("connection check errors are prefixed with DB-specific prefix", function()
        local ok, stderr = helpers.kong_exec("start --conf " .. helpers.test_conf_path, {
          pg_port = 99999,
          cassandra_port = 99999,
        })
        assert.False(ok)
        assert.matches("[" .. helpers.test_conf.database .. " error]", stderr, 1, true)
      end)
    end)
  end)

  describe("nginx_main_daemon = off", function()
    it("redirects nginx's stdout to 'kong start' stdout", function()
      local pl_utils = require "pl.utils"
      local pl_file = require "pl.file"

      local stdout_path = os.tmpname()

      finally(function()
        os.remove(stdout_path)
      end)

      local cmd = string.format("KONG_PROXY_ACCESS_LOG=/dev/stdout "    ..
                                "KONG_NGINX_MAIN_DAEMON=off %s start -c %s " ..
                                ">%s 2>/dev/null &", helpers.bin_path,
                                helpers.test_conf_path, stdout_path)

      local ok, _, _, stderr = pl_utils.executeex(cmd)
      if not ok then
        error(stderr)
      end

      helpers.wait_until(function()
        local cmd = string.format("%s health -p ./servroot", helpers.bin_path)
        return pl_utils.executeex(cmd)
      end, 10)

      local proxy_client = assert(helpers.proxy_client())

      local res = assert(proxy_client:send {
        method = "GET",
        path = "/hello",
      })
      assert.res_status(404, res) -- no Route configured
      assert(helpers.stop_kong(helpers.test_conf.prefix))

      -- TEST: since nginx started in the foreground, the 'kong start' command
      -- stdout should receive all of nginx's stdout as well.
      local stdout = pl_file.read(stdout_path)
      assert.matches([["GET /hello HTTP/1.1" 404]] , stdout, nil, true)
    end)
  end)

  describe("nginx_main_daemon = off #flaky on Travis", function()
    it("redirects nginx's stdout to 'kong start' stdout", function()
      local pl_utils = require "pl.utils"
      local pl_file = require "pl.file"

      local stdout_path = os.tmpname()

      finally(function()
        os.remove(stdout_path)
      end)

      local cmd = string.format("KONG_PROXY_ACCESS_LOG=/dev/stdout "    ..
                                "KONG_NGINX_MAIN_DAEMON=off %s start -c %s " ..
                                ">%s 2>/dev/null &", helpers.bin_path,
                                helpers.test_conf_path, stdout_path)

      local ok, _, _, stderr = pl_utils.executeex(cmd)
      if not ok then
        error(stderr)
      end

      helpers.wait_until(function()
        local cmd = string.format("%s health -p ./servroot", helpers.bin_path)
        return pl_utils.executeex(cmd)
      end, 10)

      local proxy_client = assert(helpers.proxy_client())

      local res = assert(proxy_client:send {
        method = "GET",
        path = "/hello",
      })
      assert.res_status(404, res) -- no Route configured
      assert(helpers.stop_kong(helpers.test_conf.prefix))

      -- TEST: since nginx started in the foreground, the 'kong start' command
      -- stdout should receive all of nginx's stdout as well.
      local stdout = pl_file.read(stdout_path)
      assert.matches([["GET /hello HTTP/1.1" 404]] , stdout, nil, true)
    end)
  end)

  if strategy == "off" then
    describe("declarative config start", function()
      it("starts with a valid declarative config file", function()
        local yaml_file = helpers.make_yaml_file [[
          _format_version: "1.1"
          services:
          - name: my-service
            url: http://127.0.0.1:15555
            routes:
            - name: example-route
              hosts:
              - example.test
        ]]

        local proxy_client

        finally(function()
          os.remove(yaml_file)
          helpers.stop_kong(helpers.test_conf.prefix)
          if proxy_client then
            proxy_client:close()
          end
        end)

        assert(helpers.start_kong({
          database = "off",
          declarative_config = yaml_file,
          nginx_worker_processes = 100, -- stress test initialization
          nginx_conf = "spec/fixtures/custom_nginx.template",
        }))

        helpers.wait_until(function()
          -- get a connection, retry until kong starts
          helpers.wait_until(function()
            local pok
            pok, proxy_client = pcall(helpers.proxy_client)
            return pok
          end, 10)

          local res = assert(proxy_client:send {
            method = "GET",
            path = "/",
            headers = {
              host = "example.test",
            }
          })
          local ok = res.status == 200

          if proxy_client then
            proxy_client:close()
            proxy_client = nil
          end

          return ok
        end, 10)
      end)
      it("starts with a valid declarative config string", function()
        local config_string = [[{"_format_version":"1.1","services":[{"name":"my-service","url":"http://127.0.0.1:15555","routes":[{"name":"example-route","hosts":["example.test"]}]}]}]]
        local proxy_client

        finally(function()
          helpers.stop_kong(helpers.test_conf.prefix)
          if proxy_client then
            proxy_client:close()
          end
        end)

        assert(helpers.start_kong({
          database = "off",
          declarative_config_string = config_string,
          nginx_conf = "spec/fixtures/custom_nginx.template",
        }))

        helpers.wait_until(function()
          -- get a connection, retry until kong starts
          helpers.wait_until(function()
            local pok
            pok, proxy_client = pcall(helpers.proxy_client)
            return pok
          end, 10)

          local res = assert(proxy_client:send {
            method = "GET",
            path = "/",
            headers = {
              host = "example.test",
            }
          })
          local ok = res.status == 200

          if proxy_client then
            proxy_client:close()
            proxy_client = nil
          end

          return ok
        end, 10)
      end)
    end)
  end

  describe("errors", function()
    it("start inexistent Kong conf file", function()
      local ok, stderr = helpers.kong_exec "start --conf foobar.conf"
      assert.False(ok)
      assert.is_string(stderr)
      assert.matches("Error: no file at: foobar.conf", stderr, nil, true)
    end)
    it("stop inexistent prefix", function()
      assert(helpers.kong_exec("start --prefix " .. helpers.test_conf.prefix, {
        pg_database = helpers.test_conf.pg_database,
        cassandra_keyspace = helpers.test_conf.cassandra_keyspace,
      }))

      local ok, stderr = helpers.kong_exec("stop --prefix inexistent")
      assert.False(ok)
      assert.matches("Error: no such prefix: .*/inexistent", stderr)
    end)
    it("notifies when Kong is already running", function()
      assert(helpers.kong_exec("start --prefix " .. helpers.test_conf.prefix, {
        pg_database = helpers.test_conf.pg_database,
        cassandra_keyspace = helpers.test_conf.cassandra_keyspace,
      }))

      local ok, stderr = helpers.kong_exec("start --prefix " .. helpers.test_conf.prefix, {
        pg_database = helpers.test_conf.pg_database
      })
      assert.False(ok)
      assert.matches("Kong is already running in " .. helpers.test_conf.prefix, stderr, nil, true)
    end)
    it("should not stop Kong if already running in prefix", function()
      local kill = require "kong.cmd.utils.kill"

      assert(helpers.kong_exec("start --prefix " .. helpers.test_conf.prefix, {
        pg_database = helpers.test_conf.pg_database,
        cassandra_keyspace = helpers.test_conf.cassandra_keyspace,
      }))

      local ok, stderr = helpers.kong_exec("start --prefix " .. helpers.test_conf.prefix, {
        pg_database = helpers.test_conf.pg_database
      })
      assert.False(ok)
      assert.matches("Kong is already running in " .. helpers.test_conf.prefix, stderr, nil, true)

      assert(kill.is_running(helpers.test_conf.nginx_pid))
    end)
    it("ensures the required shared dictionaries are defined", function()
      local constants = require "kong.constants"
      local pl_file   = require "pl.file"
      local fmt       = string.format

      local templ_fixture     = "spec/fixtures/custom_nginx.template"
      local new_templ_fixture = "spec/fixtures/custom_nginx.template.tmp"

      finally(function()
        pl_file.delete(new_templ_fixture)
        helpers.stop_kong()
      end)

      for _, dict in ipairs(constants.DICTS) do
        -- remove shared dictionary entry
        assert(os.execute(fmt("sed '/lua_shared_dict %s .*;/d' %s > %s",
                              dict, templ_fixture, new_templ_fixture)))

        local ok, err = helpers.start_kong({ nginx_conf = new_templ_fixture })
        assert.falsy(ok)
        assert.matches(
          "missing shared dict '" .. dict .. "' in Nginx configuration, "    ..
          "are you using a custom template? Make sure the 'lua_shared_dict " ..
          dict .. " [SIZE];' directive is defined.", err, nil, true)
      end
    end)

    if strategy == "cassandra" then
      it("errors when cassandra contact points cannot be resolved", function()
        local ok, stderr = helpers.start_kong({
          database = strategy,
          cassandra_contact_points = "invalid.inexistent.host",
          cassandra_keyspace = helpers.test_conf.cassandra_keyspace,
        })

        assert.False(ok)
        assert.matches("could not resolve any of the provided Cassandra contact points " ..
                       "(cassandra_contact_points = 'invalid.inexistent.host')", stderr, nil, true)

        finally(function()
          helpers.stop_kong()
          helpers.kill_all()
          pcall(helpers.dir.rmtree)
        end)
      end)
    end

    if strategy == "off" then
      it("does not start with an invalid declarative config file", function()
        local yaml_file = helpers.make_yaml_file [[
          _format_version: "1.1"
          services:
          - name: "@gobo"
            protocol: foo
            host: mockbin.org
          - name: my-service
            url: http://mockbin.org
            routes:
            - name: example-route
              hosts:
              - example.test
              - \\99
        ]]

        finally(function()
          os.remove(yaml_file)
          helpers.stop_kong()
        end)

        local ok, err = helpers.start_kong({
          database = "off",
          declarative_config = yaml_file,
        })

        assert.falsy(ok)
        assert.matches("in 'protocol': expected one of: grpc, grpcs, http, https, tcp, tls, tls_passthrough, udp", err, nil, true)
        assert.matches("in 'name': invalid value '@gobo': the only accepted ascii characters are alphanumerics or ., -, _, and ~", err, nil, true)
        assert.matches("in entry 2 of 'hosts': invalid hostname: \\\\99", err, nil, true)
      end)
    end

  end)

  describe("deprecated properties", function()
    describe("prints a warning to stderr", function()
      local u = helpers.unindent

      local function check_warn(opts, deprecated, replacement)
        local kopts = {
          prefix = helpers.test_conf.prefix,
          database = helpers.test_conf.database,
          pg_database = helpers.test_conf.pg_database,
          cassandra_keyspace = helpers.test_conf.cassandra_keyspace,
        }

        for k, v in pairs(opts) do
          kopts[k] = v
        end

        local _, stderr, stdout = assert(helpers.kong_exec("start", kopts))
        assert.matches("Kong started", stdout, nil, true)

        if replacement then
          assert.matches(u([[
            [warn] the ']] .. deprecated .. [[' configuration property is
            deprecated, use ']] .. replacement .. [[' instead
          ]], nil, true), stderr, nil, true)

        else
          assert.matches(u([[
            [warn] the ']] .. deprecated .. [[' configuration property is
            deprecated
          ]], nil, true), stderr, nil, true)
        end

        local _, stderr, stdout = assert(helpers.kong_exec("stop", kopts))
        assert.matches("Kong stopped", stdout, nil, true)
        assert.equal("", stderr)
      end

      it("nginx_optimizations", function()
        check_warn({
          nginx_optimizations = true,
        }, "nginx_optimizations")
      end)

      it("client_max_body_size", function()
        check_warn({
          client_max_body_size = "16k",
        }, "client_max_body_size", "nginx_http_client_max_body_size")
      end)

      it("client_body_buffer_size", function()
        check_warn({
          client_body_buffer_size = "16k",
        }, "client_body_buffer_size", "nginx_http_client_body_buffer_size")
      end)

      it("upstream_keepalive", function()
        check_warn({
          upstream_keepalive = 10,
        }, "upstream_keepalive", "upstream_keepalive_pool_size")
      end)

      it("nginx_http_upstream_keepalive", function()
        check_warn({
          nginx_http_upstream_keepalive = 10,
        }, "nginx_http_upstream_keepalive", "upstream_keepalive_pool_size")
      end)

      it("nginx_http_upstream_keepalive_requests", function()
        check_warn({
          nginx_http_upstream_keepalive_requests = 50,
        }, "nginx_http_upstream_keepalive_requests", "upstream_keepalive_max_requests")
      end)

      it("nginx_http_upstream_keepalive_timeout", function()
        check_warn({
          nginx_http_upstream_keepalive_timeout = "30s",
        }, "nginx_http_upstream_keepalive_timeout", "upstream_keepalive_idle_timeout")
      end)

      it("nginx_upstream_keepalive", function()
        check_warn({
          nginx_upstream_keepalive = 10,
        }, "nginx_upstream_keepalive", "upstream_keepalive_pool_size")
      end)

      it("nginx_upstream_keepalive_requests", function()
        check_warn({
          nginx_upstream_keepalive_requests = 10,
        }, "nginx_upstream_keepalive_requests", "upstream_keepalive_max_requests")
      end)

      it("nginx_upstream_keepalive_timeout", function()
        check_warn({
          nginx_upstream_keepalive_timeout = "30s",
        }, "nginx_upstream_keepalive_timeout", "upstream_keepalive_idle_timeout")
      end)

      it("'cassandra_consistency'", function()
        local opts = {
          prefix = helpers.test_conf.prefix,
          database = helpers.test_conf.database,
          pg_database = helpers.test_conf.pg_database,
          cassandra_keyspace = helpers.test_conf.cassandra_keyspace,
          cassandra_consistency = "LOCAL_ONE",
        }

        local _, stderr, stdout = assert(helpers.kong_exec("start", opts))
        assert.matches("Kong started", stdout, nil, true)
        assert.matches(u([[
          [warn] the 'cassandra_consistency' configuration property is
          deprecated, use 'cassandra_write_consistency / cassandra_read_consistency'
          instead
        ]], nil, true), stderr, nil, true)

        local _, stderr, stdout = assert(helpers.kong_exec("stop", opts))
        assert.matches("Kong stopped", stdout, nil, true)
        assert.equal("", stderr)
      end)
    end)
  end)
end)

end
