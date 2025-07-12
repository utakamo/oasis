let server = {};

let tool = function(obj, method, def) {
    if (server[obj] == null) {
        server[obj] = {};
    }

    server[obj][method] = def;
};

let submit = function(arg) {
    print(server);
    return server;
};

return {
    tool : tool,
    submit : submit,
};