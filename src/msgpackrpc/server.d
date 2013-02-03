// Written in the D programming language.

/**
 * MessagePack RPC Server
 */
module msgpackrpc.server;

import msgpackrpc.common;
import msgpackrpc.transport.tcp;

import msgpack;
import vibe.vibe;

import std.traits;


/**
 * MessagePack RPC Server serves Object or module based dispacher
 */
class Server(alias T, alias Protocol = msgpackrpc.transport.tcp)
{
  private:
    enum ModuleDispatcher = T.stringof.startsWith("module ");

    alias Protocol.ServerSocket!(typeof(this)) Socket;
    alias Protocol.ServerTransport!(typeof(this)) Transport;

    Transport[] _transports;

  public:
    static if (!ModuleDispatcher)
    {
        private T _dispatcher;

        this(T)(T dispatcher)
        {
            _dispatcher = dispatcher;
        }
    }

    void listen(ushort port, string address)
    {
        auto transport = new Transport(Endpoint(port, address));
        transport.listen(this);
        _transports ~= transport;
    }

    void start()
    {
        runEventLoop();
    }

    void close()
    {
        foreach (transport; _transports)
            transport.close();

        exitEventLoop();
    }

    void onRequest(Sender)(Sender socket, size_t id, string method, ref Value[] params)
    {
        try {
            Value result = dispatch(method, params);
            socket.sendResponse(id, null, result);
        } catch (Exception e) {
            socket.sendResponse(id, e.msg, null);
            //socket.sendMessage(MessageType.response, id, e, null);  // can't be compileds...
        }
    }

    void onNotify(string method, ref Value[] params)
    {
        try {
            dispatch(method, params);
        } catch (Exception e) { }  // Notify doesn't return the error;
    }

  private:
    Value dispatch(string method, ref Value[] params)
    {
        static if (ModuleDispatcher)
        {
            mixin("static import " ~ moduleName!T ~ ";");
        }

        Value result;

        switch (method) {
        mixin(generateDispatchCases!T());
        default:
            throw new NoMethodError("'%s' method not found".format(method));
        }

        return result;
    }
}

private:

string generateDispatchCases(alias T)()
{
    static if (T.stringof.startsWith("module "))
    {
        return generateDispatchCasesForModule!(T)();
    }
    else
    {
        return generateDispatchCasesForObject!(T)();
    }
}

string generateDispatchCasesForModule(alias T)()
{
    static assert(T.stringof.startsWith("module "), "T must be module");

    alias moduleName!T fullyModuleName;
    mixin("import " ~ moduleName!T ~ ";");

    string result;

	foreach (method; __traits(allMembers, T)) {
        static if (!__traits(compiles, __traits(getMember, T, method).stringof.startsWith("template ")))
        {
            enum name = fullyModuleName ~ "." ~ method;

            //static assert(__traits(getOverloads, T, method).length != 1, "The function of RPC dispatcher doesn't allow the overloads: function = " ~ name);

            static if (__traits(compiles, ParameterTypeTuple!(mixin(name))))
            {
                alias ParameterTypeTuple!(mixin(name)) ParameterTypes;
                alias ReturnType!(mixin(name)) RT;

                result ~= genetateCaseBody!(fullyModuleName, method, RT, ParameterTypes)();
            }
        }
    }

    return result;
}

string generateDispatchCasesForObject(alias T)()
{
    import std.algorithm : canFind;
    import std.string;

    static immutable string[] builtinFunctions = ["__ctor", "__dtor", "opEquals", "opCmp", "toHash", "toString", "Monitor", "factory"];

    string result;

	foreach (method; __traits(allMembers, T)) {
		alias MemberFunctionsTuple!(T, method) funcs;

        // The result of member variables is "funcs.length == 0"
        static if (funcs.length > 0 && !canFind(builtinFunctions, method))
        {
            static assert(funcs.length == 1, "The function of RPC dispatcher doesn't allow the overloads: function = " ~ method);

            alias typeof(funcs[0]) func;
            alias ParameterTypeTuple!func ParameterTypes;
            alias ReturnType!func RT;

            result ~= genetateCaseBody!("_dispatcher", method, RT, ParameterTypes)();
       }
    }

    return result;
}

string genetateCaseBody(string prefix, string name, RT, ParameterTypes...)()
{
    string result;

    static if (ParameterTypes.length > 0)
    {
        result ~= q"CASE
case "%s":
if (params.length != %s)
    throw new ArgumentError("the number of '%s' parameters is mismatched");
CASE".format(name, ParameterTypes.length, name);
    }
    else
    {
        result ~= "case \"%s\":\n".format(name);
    }

    static if (is(RT == void))
    {
        result ~= q"CASE
%s.%s(%s);
CASE".format(prefix, name, generateParameters!(ParameterTypes)());
    }
    else
    {
        // TODO: Support struct and class return type.
        result ~= q"CASE
result = Value(%s.%s(%s));
CASE".format(prefix, name, generateParameters!(ParameterTypes)());
    }

    result ~= "break;\n";

    return result;
}

string generateParameters(Types...)()
{
    string result;

    foreach (i, Type; Types) {
        if (i > 0)
            result ~= ", ";
        result ~= "params[%s].as!(%s)".format(i, Type.stringof);
    }

    return result;
}