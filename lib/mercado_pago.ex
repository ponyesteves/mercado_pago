defmodule MercadoPago do
  alias MercadoPago.Extract

  @api_domain "https://api.mercadopago.com/"
  @ep_token @api_domain <> "oauth/token"
  @grant_type_access "client_credentials"
  @ep_checkout @api_domain <> "checkout/preferences"
  @payment_methods Application.get_env(:mercado_pago, :payment_methods) || []

  # Based on config it creates methods named after the available payment_methods
  # i.e if config :mercado_pago, payment_methods: ["rapipago", "pagofacil"]
  # it creates get_link_and_rapipago_code and get_link_and_pagomiscuentas_code

  for name <- @payment_methods do
    def unquote(String.to_atom("get_link_and_" <> name <> "_code"))(title, description, amount) do
      get_payment_link(title, description, amount, payment_method: unquote(name))
      |> find_code(payment_method: unquote(name))
    end
  end

  def get_payment_link(title, description, amount, opts \\ []) do
    IO.puts "GETTING PAYMENT LINK..."
    retrying = opts[:retry]
    case req_link(title, description, amount, opts) do
      {:ok, %HTTPoison.Response{status_code: sc, body: body}} when sc >= 400 and retrying ->
        IO.inspect body
      {:ok, %HTTPoison.Response{status_code: sc}} when sc >= 400 ->
        new_token()
        get_payment_link(title, description, amount,  opts ++ [retry: true])

      {:ok, %HTTPoison.Response{body: body}} ->
        Poison.decode!(body)
        |> Map.get("init_point")

      {:error, _} ->
        IO.inspect("ERROR")
    end
  end

  def get_token do
    Agent.get(:mp_token, fn state -> state end) || new_token
  end

  defp find_code(link, opts \\ []) do
    IO.puts "FINDING CODE..."
    try do
      case HTTPoison.get(link) do
        {:ok, %HTTPoison.Response{headers: headers, body: body}} ->
          action = Extract.form_action(body)
          execution = Extract.input(body, "execution")
          rej64 = Extract.input(body, "rej64")
          cookies = Extract.cookies(headers)

          res = HTTPoison.post!(action, {:form, [execution: execution, payment_option_id: "rapipago", rej64: rej64, _eventId_next: "", email: Application.get_env(:mercado_pago, :no_reply_mail)]}, [], hackney: [cookie: cookies])
          |> Map.get(:body)

          code = Regex.named_captures(~r/paymentId: '(?<code>\d+)'/, res)["code"]
          |> String.split_at(5) |> Tuple.to_list |> Enum.join("-")
          {:ok, link, code}
     end
    rescue
      _ -> {:error, link}
    end
  end

  defp new_token() do
    case req_new_token do
      {:ok, %HTTPoison.Response{body: body}} ->
        Poison.decode!(body)
        |> save_token

      {:error, _} ->
        IO.puts("Error retriving token... trying again in 10 secs")
        :timer.sleep(10000)
        new_token()
    end
  end

  defp req_new_token do
    HTTPoison.post(
      @ep_token,
      token_payload
    )
  end

  defp token_payload do
    {:form,
     [
       client_id:
         Application.get_env(:mercado_pago, :client_id) || missing_conf_error("client_id"),
       client_secret:
         Application.get_env(:mercado_pago, :client_secret) || missing_conf_error("client_secret"),
       grant_type: @grant_type_access
     ]}
  end

  defp req_link(title, description, amount, opts) do
    HTTPoison.post(
      end_point_url(get_token()),
      link_payload(title, description, amount, opts) |> Poison.encode!(),
      [{"Content-Type", "application/json"}]
    )
  end

  defp base_link_payload(title, description, amount) do
    %{
      items: [
        %{
          title: title,
          description: description,
          quantity: 1,
          currency_id: "ARS",
          unit_price: amount
        }
      ]
    }
  end

  defp link_payload(title, description, amount, []) do
    base_link_payload(title, description, amount)
  end

  defp link_payload(title, description, amount, [{:payment_method, payment_method} | _]) do
    base_link_payload(title, description, amount)
    |> Map.put(:payment_methods, %{
      default_payment_method_id: payment_method
    })
  end

  defp save_token(token) do
    Agent.update(:mp_token, fn _ -> token["access_token"] end)
    token["access_token"]
  end

  defp end_point_url(token) do
    @ep_checkout <> "?access_token=" <> token
  end

  defp missing_conf_error(key) do
    IO.puts("#{key} config missing")
  end
end
