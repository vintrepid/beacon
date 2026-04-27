defmodule Mix.Tasks.Beacon.Install.Docs do
  @moduledoc false

  def short_doc, do: "Installs Beacon in a Phoenix LiveView app and generates a single site."

  def example, do: "mix beacon.install --site my_site --path /"

  def long_doc do
    """
    #{short_doc()}

    This is the raftwet-fork installer. It combines what upstream's
    `beacon.install` and `beacon.gen.site` used to do, but only the parts
    needed for a single-site, single-endpoint Beacon installation that
    reuses the host app's Repo and Endpoint.

    It will:

      * import `:beacon` formatter rules
      * use `Beacon.Web.ErrorHTML` for `:html` render_errors
      * add `use Beacon.Router` to your router
      * add a `:beacon` pipeline using `Beacon.Plug`
      * mount `beacon_site` at the requested path
      * add a Beacon child to your application supervisor
      * write `:beacon, <SiteName>` config to `config/runtime.exs`
      * create a migration that calls `Beacon.Migration.up/down`

    It does NOT generate `Beacon.LiveAdmin` wiring — run
    `mix beacon_live_admin.install --path /admin/beacon` afterwards.

    ## Options

      * `--site` (required) - The site name. Atom-friendly. Cannot start with `beacon_`.
      * `--path` (optional, default `"/"`) - Where the site mounts in the router.
    """
  end
end

if Code.ensure_loaded?(Igniter) do
  defmodule Mix.Tasks.Beacon.Install do
    @shortdoc "#{__MODULE__.Docs.short_doc()}"

    @moduledoc __MODULE__.Docs.long_doc()

    use Igniter.Mix.Task

    @impl Igniter.Mix.Task
    def supports_umbrella?, do: false

    @impl Igniter.Mix.Task
    def info(_argv, _composing_task) do
      %Igniter.Mix.Task.Info{
        group: :beacon,
        example: __MODULE__.Docs.example(),
        schema: [site: :string, path: :string],
        defaults: [path: "/"],
        required: [:site]
      }
    end

    @impl Igniter.Mix.Task
    def igniter(igniter) do
      opts = igniter.args.options
      site_string = Keyword.fetch!(opts, :site)
      path = Keyword.fetch!(opts, :path)

      validate!(site_string, path)
      site = String.to_atom(site_string)

      app = Igniter.Project.Application.app_name(igniter)
      web_module = Igniter.Libs.Phoenix.web_module(igniter)
      {igniter, router} = select_router!(igniter)
      endpoint = Module.concat([web_module, Endpoint])
      repo = Module.concat([Macro.camelize(to_string(app)), Repo])

      igniter
      |> Igniter.Project.Formatter.import_dep(:beacon)
      |> configure_render_errors(app, endpoint)
      |> add_router_use(router)
      |> add_beacon_pipeline(router)
      |> remove_conflicting_root_route(router, path)
      |> mount_beacon_site(router, site, path)
      |> add_supervisor_child(site, repo)
      |> add_runtime_config(site, repo, endpoint, router)
      |> create_migration(repo, site)
      |> Igniter.add_notice("""
      Beacon installed for site #{inspect(site)} at path #{inspect(path)}.

      Next steps:
        1. Run: mix ecto.migrate
        2. Install LiveAdmin: mix beacon_live_admin.install --path /admin/beacon
        3. Boot the app and visit #{path} (Beacon site) and /admin/beacon (LiveAdmin)
      """)
    end

    defp validate!(site, path) do
      unless Beacon.Types.Site.valid?(site) do
        Mix.raise(
          "Invalid --site value #{inspect(site)}. Use letters, digits, and underscores; do not start with `beacon_`."
        )
      end

      unless Beacon.Types.Site.valid_path?(path) do
        Mix.raise("Invalid --path value #{inspect(path)}. Must start with `/`.")
      end
    end

    defp select_router!(igniter) do
      case Igniter.Libs.Phoenix.select_router(igniter, "Which router should be modified?") do
        {_igniter, nil} -> Mix.raise("No Phoenix router found.")
        found -> found
      end
    end

    defp configure_render_errors(igniter, app, endpoint) do
      Igniter.Project.Config.configure(
        igniter,
        "config.exs",
        app,
        [endpoint, :render_errors, :formats, :html],
        Beacon.Web.ErrorHTML
      )
    end

    defp add_router_use(igniter, router) do
      web_module = Igniter.Libs.Phoenix.web_module(igniter)

      Igniter.Project.Module.find_and_update_module!(igniter, router, fn zipper ->
        case Igniter.Code.Module.move_to_use(zipper, Beacon.Router) do
          {:ok, _zipper} ->
            {:ok, zipper}

          :error ->
            zipper =
              case Igniter.Code.Module.move_to_use(zipper, web_module) do
                {:ok, found} ->
                  Igniter.Code.Common.add_code(found, "use Beacon.Router", placement: :after)

                :error ->
                  Igniter.Code.Common.add_code(zipper, "use Beacon.Router", placement: :after)
              end

            {:ok, zipper}
        end
      end)
    end

    defp remove_conflicting_root_route(igniter, router, path) do
      Igniter.Project.Module.find_and_update_module!(igniter, router, fn zipper ->
        target =
          Sourceror.Zipper.find(zipper, fn node ->
            match?(
              {:get, _, [{:__block__, _, [^path]}, {:__aliases__, _, _}, {:__block__, _, [_]}]},
              node
            )
          end)

        case target do
          nil ->
            {:ok, zipper}

          found ->
            {:ok, Sourceror.Zipper.remove(found)}
        end
      end)
    end

    defp add_beacon_pipeline(igniter, router) do
      Igniter.Libs.Phoenix.add_pipeline(
        igniter,
        :beacon,
        "plug Beacon.Plug",
        router: router
      )
    end

    defp mount_beacon_site(igniter, router, site, path) do
      scope_source = """

      scope #{inspect(path)} do
        pipe_through [:browser, :beacon]
        beacon_site #{inspect(path)}, site: #{inspect(site)}
      end
      """

      Igniter.Project.Module.find_and_update_module!(igniter, router, fn zipper ->
        zipper =
          case Sourceror.Zipper.down(zipper) do
            nil -> zipper
            inner -> Sourceror.Zipper.rightmost(inner)
          end

        zipper = Igniter.Code.Common.add_code(zipper, scope_source, placement: :after)
        {:ok, zipper}
      end)
    end

    defp add_supervisor_child(igniter, site, repo) do
      Igniter.Project.Application.add_new_child(
        igniter,
        {Beacon,
         {:code,
          quote do
            [sites: [Application.fetch_env!(:beacon, unquote(site))]]
          end}},
        after: [repo],
        opts_updater: fn zipper ->
          with {:ok, zipper} <-
                 Igniter.Code.Keyword.put_in_keyword(
                   zipper,
                   [:sites],
                   Sourceror.parse_string!("[Application.fetch_env!(:beacon, :#{site})]"),
                   fn zipper ->
                     case Sourceror.Zipper.find(
                            zipper,
                            &match?(
                              {{_, _, [{_, _, [:Application]}, :fetch_env!]}, _,
                               [{_, _, [:beacon]}, {_, _, [^site]}]},
                              &1
                            )
                          ) do
                       nil ->
                         Igniter.Code.List.append_to_list(
                           zipper,
                           Sourceror.parse_string!("Application.fetch_env!(:beacon, :#{site})")
                         )

                       _found ->
                         {:ok, zipper}
                     end
                   end
                 ) do
            {:ok, zipper}
          end
        end
      )
    end

    defp add_runtime_config(igniter, site, repo, endpoint, router) do
      igniter
      |> Igniter.Project.Config.configure(
        "runtime.exs",
        :beacon,
        [site, :site],
        {:code, Sourceror.parse_string!(":#{site}")}
      )
      |> Igniter.Project.Config.configure(
        "runtime.exs",
        :beacon,
        [site, :repo],
        {:code, Sourceror.parse_string!(inspect(repo))}
      )
      |> Igniter.Project.Config.configure(
        "runtime.exs",
        :beacon,
        [site, :endpoint],
        {:code, Sourceror.parse_string!(inspect(endpoint))}
      )
      |> Igniter.Project.Config.configure(
        "runtime.exs",
        :beacon,
        [site, :router],
        {:code, Sourceror.parse_string!(inspect(router))}
      )
    end

    defp create_migration(igniter, repo, site) do
      timestamp =
        DateTime.utc_now()
        |> Calendar.strftime("%Y%m%d%H%M%S")

      migration_name = "create_beacon_tables_for_#{site}"

      module =
        Module.concat([repo, Migrations, "V#{timestamp}#{Macro.camelize(migration_name)}"])

      relative = "priv/repo/migrations/#{timestamp}_#{migration_name}.exs"

      contents = """
      defmodule #{inspect(module)} do
        use Ecto.Migration

        def up, do: Beacon.Migration.up()
        def down, do: Beacon.Migration.down()
      end
      """

      Igniter.create_new_file(igniter, relative, contents, on_exists: :skip)
    end
  end
else
  defmodule Mix.Tasks.Beacon.Install do
    @shortdoc "#{__MODULE__.Docs.short_doc()}"

    @moduledoc __MODULE__.Docs.long_doc()

    use Mix.Task

    def run(_argv) do
      Mix.shell().error("""
      The task 'beacon.install' requires Igniter to be available.

      Add `{:igniter, "~> 0.6", only: [:dev, :test]}` to your mix.exs and run `mix deps.get`,
      then re-run this task.
      """)

      exit({:shutdown, 1})
    end
  end
end
