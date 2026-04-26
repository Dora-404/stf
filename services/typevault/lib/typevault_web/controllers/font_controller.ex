defmodule TypeVaultWeb.FontController do
  use TypeVaultWeb, :controller

  alias TypeVault.{Fonts, Repo, TvfParser, TVFValidator, Guardian}
  alias TypeVault.Fonts.FontFile

  action_fallback TypeVaultWeb.FallbackController

  @max_file_size 5_000_000

  def download_file(conn, %{"id" => id}) do
    user = conn.assigns[:current_user]
    font = Repo.get(FontFile, id) |> Repo.preload(:project)

    cond do
      is_nil(font) ->
        conn |> put_status(:not_found) |> text("Font not found")

      font.project.is_public ->
        serve_download(conn, font)

      user && font.project.user_id == user.id ->
        serve_download(conn, font)

      true ->
        conn |> put_status(:forbidden) |> text("Access denied")
    end
  end

  defp serve_download(conn, font) do
    conn
    |> put_resp_content_type("application/octet-stream")
    |> put_resp_header("content-disposition", ~s(attachment; filename="#{font.filename}"))
    |> send_resp(200, font.data)
  end

  def upload(conn, %{"project_id" => project_id} = params) do
    user = Guardian.Plug.current_resource(conn)

    with project when not is_nil(project) <- Fonts.get_project_for_user(project_id, user.id) do
      case params["font"] do
        %Plug.Upload{} = upload ->
          do_upload(conn, project, upload)

        _ ->
          conn
          |> put_status(:bad_request)
          |> json(%{error: "font file required"})
      end
    else
      nil -> {:error, :not_found}
    end
  end

  def list(conn, %{"project_id" => project_id}) do
    user = Guardian.Plug.current_resource(conn)

    with {:ok, _project} <- Fonts.get_accessible_project(project_id, user.id) do
      fonts = Fonts.list_project_fonts(project_id)
      json(conn, %{fonts: fonts})
    end
  end

  def show(conn, %{"project_id" => project_id, "id" => id}) do
    user = Guardian.Plug.current_resource(conn)

    with {:ok, _project} <- Fonts.get_accessible_project(project_id, user.id),
         font when not is_nil(font) <- Fonts.get_font_file(id),
         true <- font.project_id == project_id do
      json(conn, %{font: font_json(font)})
    else
      nil -> {:error, :not_found}
      false -> {:error, :not_found}
      error -> error
    end
  end

  def delete(conn, %{"project_id" => project_id, "id" => id}) do
    user = Guardian.Plug.current_resource(conn)

    with project when not is_nil(project) <- Fonts.get_project_for_user(project_id, user.id),
         font when not is_nil(font) <- Fonts.get_font_file(id),
         true <- font.project_id == project.id,
         {:ok, _} <- Repo.delete(font) do
      send_resp(conn, :no_content, "")
    else
      nil -> {:error, :not_found}
      false -> {:error, :forbidden}
      error -> error
    end
  end

  def preview(conn, %{"project_id" => project_id, "id" => id} = params) do
    user = Guardian.Plug.current_resource(conn)
    text = Map.get(params, "text", "Abc 123")
    size = Map.get(params, "size", 48) |> parse_int(48)

    with {:ok, project} <- Fonts.get_accessible_project(project_id, user.id),
         font when not is_nil(font) <- Fonts.get_font_file(id),
         true <- font.project_id == project_id,
         {:ok, svg} <- TvfParser.render_text(font.data, text, size) do

      callback_response = maybe_trigger_callback(font)

      if project.is_public, do: Fonts.increment_downloads(project_id)

      conn
      |> put_resp_content_type("application/json")
      |> json(%{
        svg: svg,
        font_name: get_in(font.parsed_metadata, ["font_name"]),
        callback_status: if(callback_response, do: "triggered", else: "skipped"),
        callback_response: callback_response
      })
    else
      nil -> {:error, :not_found}
      false -> {:error, :not_found}
      error -> error
    end
  end

  def preview_draft(conn, %{"project_id" => project_id} = params) do
    user = Guardian.Plug.current_resource(conn)
    font_b64 = Map.get(params, "font", "")

    with {:ok, project} <- Fonts.get_accessible_project(project_id, user.id),
         {:decode, {:ok, raw_bytes}} <- {:decode, Base.decode64(font_b64, ignore: :whitespace)},
         {:validate, true} <- {:validate, TVFValidator.safe?(raw_bytes)},
         {:ok, svg} <- TvfParser.render_preview(raw_bytes, project.design_notes || "") do
      json(conn, %{svg: svg})
    else
      {:error, :not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "project not found"})

      {:decode, _} ->
        conn |> put_status(:bad_request) |> json(%{error: "font must be valid base64"})

      {:validate, false} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: "font validation failed"})

      {:error, reason} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: inspect(reason)})
    end
  end

  defp do_upload(conn, project, %Plug.Upload{path: path, filename: filename}) do
    with {:ok, data} <- File.read(path),
         true <- byte_size(data) <= @max_file_size || {:error, :file_too_large},
         {:ok, parsed} <- TvfParser.parse_font(data),
         {:ok, font_file} <-
           Fonts.create_font_file(
             %{
               filename: sanitize_filename(filename),
               data: data,
               file_size: byte_size(data),
               format: "tvf",
               parsed_metadata: parsed.metadata
             },
             project.id
           ) do
      conn
      |> put_status(:created)
      |> json(%{font: font_json(font_file), parsed: parsed})
    end
  end

  defp maybe_trigger_callback(%{callback_triggered_at: triggered_at})
       when not is_nil(triggered_at) do
    nil
  end

  defp maybe_trigger_callback(font) do
    callback_url = get_in(font.parsed_metadata || %{}, ["preview_callback_url"])

    if callback_url do
      case TvfParser.validate_callback_url(callback_url) do
        {:ok, resolved_url} ->
          response_body = pull_render_manifest(resolved_url, font.id)
          Fonts.update_font_callback(font.id, response_body)
          response_body

        {:error, _reason} ->
          nil
      end
    else
      nil
    end
  end

  @http_opts [follow_redirect: false, timeout: 5_000, recv_timeout: 5_000]

  defp pull_render_manifest(url, font_id) do
    if private_callback_target?(url) do
      "callback rejected"
    else
      do_pull_render_manifest(url, font_id)
    end
  end

  defp do_pull_render_manifest(url, font_id) do
    headers = [
      {"User-Agent", "TypeVault/1.0 FontPreviewCallback"},
      {"X-Font-ID", font_id}
    ]

    case HTTPoison.get(url, headers, @http_opts) do
      {:ok, %HTTPoison.Response{status_code: status, body: body}} when status in 200..299 ->
        String.slice(body, 0, 65536)

      {:ok, %HTTPoison.Response{status_code: status}} ->
        "callback returned HTTP #{status}"

      {:error, %HTTPoison.Error{reason: reason}} ->
        "callback error: #{inspect(reason)}"
    end
  end

  defp private_callback_target?(url) do
    host =
      case URI.parse(url) do
        %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host) ->
          host |> String.downcase() |> String.trim_trailing(".")

        _ ->
          ""
      end

    # Strip IPv6 brackets if present
    bare = if String.starts_with?(host, "[") and String.ends_with?(host, "]") do
      String.slice(host, 1..-2//1)
    else
      host
    end

    cond do
      bare in ["", "localhost", "0", "0.0.0.0", "::1", "0:0:0:0:0:0:0:1"] -> true
      String.ends_with?(bare, ".localhost") -> true
      String.starts_with?(bare, "127.") -> true
      String.starts_with?(bare, "10.") -> true
      String.starts_with?(bare, "192.168.") -> true
      Regex.match?(~r/^172\.(1[6-9]|2\d|3[0-1])\./, bare) -> true
      String.starts_with?(bare, "169.254.") -> true
      # IPv6 loopback, link-local, unique local, IPv4-mapped
      String.starts_with?(bare, "fe80") -> true
      String.starts_with?(bare, "fc") -> true
      String.starts_with?(bare, "fd") -> true
      String.starts_with?(bare, "::ffff:127.") -> true
      String.starts_with?(bare, "::ffff:10.") -> true
      String.starts_with?(bare, "::ffff:192.168.") -> true
      Regex.match?(~r/^::ffff:172\.(1[6-9]|2\d|3[0-1])\./, bare) -> true
      # Octal/hex numeric IP representation bypass attempts
      Regex.match?(~r/^0x/, bare) -> true
      Regex.match?(~r/^0[0-9]/, bare) -> true
      true -> false
    end
  end

  defp font_json(f) do
    %{
      id: f.id,
      filename: f.filename,
      file_size: f.file_size,
      format: f.format,
      parsed_metadata: f.parsed_metadata,
      callback_response: f.callback_response,
      callback_triggered_at: f.callback_triggered_at,
      inserted_at: f.inserted_at
    }
  end

  defp sanitize_filename(name) do
    name
    |> Path.basename()
    |> String.replace(~r/[^a-zA-Z0-9._-]/, "_")
    |> String.slice(0, 255)
  end

  defp parse_int(value, default) when is_integer(value), do: value

  defp parse_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} when n > 0 -> n
      _ -> default
    end
  end

  defp parse_int(_, default), do: default
end
