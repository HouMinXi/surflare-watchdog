.outbounds[]?
| select((.tag // "") | startswith("public_"))
| select((.server // "") != "" and .server != "127.0.0.1")
| "\(.tag) \(.server)"
