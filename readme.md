With ex_anywhere, we can use elixir library in iex and .exs, don't need to create a mix project 

# install
```bash
git clone https://github.com/zelixir/ex_anywhere.git
ln -s $(pwd)/ex_anywhere/ex_anywhere.exs /usr/local/bin/exa
```

# install (on windows)

```bash
git clone https://github.com/zelixir/ex_anywhere.git
copy ex_anywhere\ex_anywhere.exs "c:\Program Files (x86)\Elixir\bin\exa"
```

`c:\Program Files (x86)\Elixir\bin\exa.bat` :
```bat
@if defined ELIXIR_CLI_ECHO (@echo on) else (@echo off)
call "%~dp0\elixir.bat" "%~dp0\exa" %*
```


# use in iex

```
iex -S exa
```

```elixir
iex(1)> deps :httpotion
:ok
iex(2)> deps :jason
:ok
iex(3)> resp = HTTPotion.get! "http://127.0.0.1:5500/123.json"
%HTTPotion.Response{
  body: "{\"name\":\"Alice\"}",
  headers: %HTTPotion.Headers{
    hdrs: %{
      "accept-ranges" => "bytes",
      "access-control-allow-credentials" => "true",
      "cache-control" => "public, max-age=0",
      "connection" => "keep-alive",
      "content-length" => "16",
      "content-type" => "application/json; charset=UTF-8",
      "date" => "Tue, 20 Nov 2018 01:02:04 GMT",
      "etag" => "W/\"10-1672e91515d\"",
      "last-modified" => "Tue, 20 Nov 2018 00:42:14 GMT",
      "vary" => "Origin"
    }
  },
  status_code: 200
}
iex(4)> json = resp.body
"{\"name\":\"Alice\"}"
iex(5)> json = Jason.decode! json
%{"name" => "Alice"}
```



# use in .exs

test.exs
```elixir
# we can require dependence by name
deps :httpotion
# or use the mix.exs format
deps {:jason, "~> 1.0"}

[url | _] = System.argv
resp = HTTPotion.get! url
json = resp.body
IO.puts json
json = Jason.decode! json
IO.puts json["name"]
```

```
exa test.exs http://127.0.0.1:5500/123.json
{"name":"Alice"}
Alice
```

# maintenance

`exa` will install a mix project at `~/.ex_anywhere/ex_anywhere`, as a local cache.

If something went wrong, check this project.




