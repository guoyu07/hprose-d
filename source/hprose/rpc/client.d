﻿/**********************************************************\
|                                                          |
|                          hprose                          |
|                                                          |
| Official WebSite: http://www.hprose.com/                 |
|                   http://www.hprose.org/                 |
|                                                          |
\**********************************************************/

/**********************************************************\
 *                                                        *
 * hprose/rpc/client.d                                    *
 *                                                        *
 * hprose client library for D.                           *
 *                                                        *
 * LastModified: Jan 13, 2016                             *
 * Author: Ma Bingyao <andot@hprose.com>                  *
 *                                                        *
\**********************************************************/

module hprose.rpc.client;

import hprose.io;
import hprose.rpc.common;
import hprose.rpc.context;
import hprose.rpc.filter;
import std.conv;
import std.stdio;
import std.string;
import std.traits;
import std.typecons;
import std.variant;

private {
    pure string generateMethods(alias methods, T, string namespace)(string code) {
        static if (methods.length > 0) {
            alias STC = ParameterStorageClass;
            enum m = methods[0];
            foreach(mm; __traits(getVirtualMethods, T, m)) {
                string name = m;
                ResultMode mode = ResultMode.Normal;
                bool simple = false;
                code ~= "    override ";
                enum attrs = __traits(getAttributes, mm);
                foreach (attr; attrs) {
                    static if (is(typeof(attr) == MethodName)) {
                        name = attr.value;
                    }
                    else static if (is(typeof(attr) == ResultMode)) {
                        mode = attr;
                    }
                    else static if (is(typeof(attr) == Simple)) {
                        simple = attr.value;
                    }
                }
                alias paramTypes = ParameterTypeTuple!(mm);
                alias paramStors = ParameterStorageClassTuple!(mm);
                alias paramIds = ParameterIdentifierTuple!(mm);
                alias paramValues = ParameterDefaultValueTuple!(mm);
                alias returntype = ReturnType!(mm);
                alias variadic = variadicFunctionStyle!(mm);
                code ~= returntype.stringof ~ " " ~ m ~ "(";
                bool byref = false;
                foreach(i, p; paramTypes) {
                    static if (i > 0) {
                        code ~= ", ";
                    }
                    static if (paramStors[i] == STC.out_ || paramStors[i] == STC.ref_ || paramStors[i] == STC.return_) {
                        byref = true;
                    }
                    final switch (paramStors[i]) {
                        case STC.none: break;
                        case STC.scope_: code ~= "scope "; break;
                        case STC.out_: code ~= "out "; break;
                        case STC.ref_: code ~= "ref "; break;
                        case STC.lazy_: code ~= "lazy "; break;
                        case STC.return_: code ~= "return ref "; break;
                    }
                    static if (paramIds[i] != "") {
                        code ~= p.stringof ~ " " ~ paramIds[i];
                    }
                    else {
                        code ~= p.stringof ~ " arg" ~ to!string(i);
                    }
                    static if (!is(paramValues[i] == void)) {
                        code ~= " = " ~ paramValues[i].stringof;
                    }
                }
                static if (variadic == Variadic.typesafe) {
                    code ~= "...";
                }
                code ~= ") {\n";
                static if (is(returntype == void)) {
                    static if (paramTypes.length > 0 && is(paramTypes[$-1] == return)) {
                        alias Callback = paramTypes[$-1];
                        alias callbackParams = ParameterTypeTuple!Callback;
                        static if (callbackParams.length == 0) {
                            code ~= "        invoke(\"";
                        }
                        else static if (callbackParams.length == 1) {
                            code ~= "        invoke!(";
                        }
                        else static if (callbackParams.length > 1) {
                            foreach(s; ParameterStorageClassTuple!Callback) {
                                static if (s == STC.out_ || s == STC.ref_) {
                                    byref = true;
                                }
                            }
                            code ~= "        invoke!(" ~ to!string(byref) ~ ", ";
                        }
                        else {
                            static assert(0, "can't support this callback type: " ~ Callback.stringof);
                        }
                        static if (callbackParams.length > 0) {
                            code ~= "ResultMode." ~ to!string(mode) ~ ", " ~
                                to!string(simple) ~ ")(\"";
                        }
                    }
                    else {
                        code ~= "        invoke!(" ~ returntype.stringof ~ ", " ~
                            to!string(byref) ~ ", " ~
                                "ResultMode." ~ to!string(mode) ~ ", " ~
                                to!string(simple) ~ ")(\"";
                    }
                }
                else {
                    code ~= "        return invoke!(" ~ returntype.stringof ~ ", " ~
                        to!string(byref) ~ ", " ~
                            "ResultMode." ~ to!string(mode) ~ ", " ~
                            to!string(simple) ~ ")(\"";
                }
                static if (namespace != "") {
                    code ~= namespace ~ "_";
                }
                code ~= name ~ "\"" ;
                foreach(i, id; paramIds) {
                    static if (id != "") {
                        code ~= ", " ~ id;
                    }
                    else {
                        code ~= ", arg" ~ to!string(i);
                    }
                }
                code ~= ");\n";
                code ~= "    }\n";
            }
            static if (methods.length > 1) {
                code = generateMethods!(tuple(methods[1..$]), T, namespace)(code);
            }
        }
        return code;
    }

    pure string generate(T, string namespace)() {
        return generateMethods!(getAbstractMethods!(T), T, namespace)("new class T {\n") ~ "}\n";
    }

    pure string asyncInvoke(bool byref, bool hasresult, bool hasargs)() {
        string code = "foreach(T; Args) static assert(isSerializable!T);\n";
        code ~= "try {\n";
        code ~= "    auto context = new Context();\n";
        code ~= "    auto request = doOutput!(" ~ to!string(byref) ~ ", simple)(name, context, args);\n";
        code ~= "    sendAndReceive(request, delegate(ubyte[] response) {\n";
        code ~= "        try {\n";
        code ~= "            auto result = doInput!(Result, mode)(response, context, args);\n";
        code ~= "            if (callback !is null) {\n";
        code ~= "                callback(" ~ (hasresult ? "result" ~ (hasargs ? ", args" : "") : "") ~ ");\n";
        code ~= "            }\n";
        code ~= "        }\n";
        code ~= "        catch(Exception e) {\n";
        code ~= "            if (onError !is null) onError(name, e);\n";
        code ~= "        }\n";
        code ~= "    });\n";
        code ~= "}\n";
        code ~= "catch(Exception e) {\n";
        code ~= "    if (onError !is null) onError(name, e);\n";
        code ~= "}\n";
        return code;
    }
}

abstract class Client {
    private {
        Filter[] _filters;
        ubyte[] doOutput(bool byref, bool simple, Args...)(string name, Context context, ref Args args) {
            auto bytes = new BytesIO();
            auto writer = new Writer(bytes, simple);
            bytes.write(TagCall);
            writer.writeString(name);
            if (args.length > 0 || byref) {
                writer.reset();
                writer.writeTuple(args);
                static if (byref) {
                    writer.writeBool(true);
                }
            }
            bytes.write(TagEnd);
            auto request = cast(ubyte[])(bytes.buffer);
            bytes.close();
            foreach(filter; _filters) {
                request = filter.outputFilter(request, context);
            }
            return request;
        }
        Result doInput(Result, ResultMode mode, Args...)(ubyte[]response, Context context, ref Args args) if (mode == ResultMode.Normal || is(Result == ubyte[])) {
            foreach_reverse(filter; _filters) {
                response = filter.inputFilter(response, context);
            }
            static if (mode == ResultMode.RawWithEndTag) {
                return response;
            }
            else static if (mode == ResultMode.Raw) {
                return response[0..$-1];
            }
            else {
                auto bytes = new BytesIO(response);
                auto reader = new Reader(bytes);
                Result result;
                char tag;
                while((tag = bytes.read()) != TagEnd) {
                    switch(tag) {
                        case TagResult: {
                            static if (mode == ResultMode.Serialized) {
                                result = cast(ubyte[])(reader.readRaw().buffer);
                            }
                            else {
                                reader.reset();
                                result = reader.unserialize!Result();
                            }
                            break;
                        }
                        case TagArgument: {
                            reader.reset();
                            reader.readTuple(args);
                            break;
                        }
                        case TagError: {
                            reader.reset();
                            throw new Exception(reader.unserialize!string());
                        }
                        default: {
                            throw new Exception("Wrong Response: \r\n" ~ cast(string)response);
                        }
                    }
                }
                bytes.close();
                return result;
            }
        }
    }
    protected {
        string uri;
        abstract ubyte[] sendAndReceive(ubyte[] request);
        abstract void sendAndReceive(ubyte[] request, void delegate(ubyte[]) callback);
    }

    void delegate(string name, Exception e) onError = null;

    this(string uri = "") {
        this.uri = uri;
        this._filters = [];
    }
    void useService(string uri = "") {
        if (uri != "") {
            this.uri = uri;
        }
    }
    T useService(T, string namespace = "")(string uri = "") if (is(T == interface) || is(T == class)) {
        useService(uri);
        return mixin(generate!(T, namespace));
    }
    Result invoke(Result, bool byref = false, ResultMode mode = ResultMode.Normal, bool simple = false, Args...)
        (string name, Args args) if (args.length > 0 && byref == false && !is(typeof(args[$-1]) == return) &&
        (mode == ResultMode.Normal || is(Result == ubyte[]))) {
        static if (is(Result == void)) {
            invoke!(Result, byref, mode, simple)(name, args);
        }
        else {
            return invoke!(Result, byref, mode, simple)(name, args);
        }
    }
    Result invoke(Result, bool byref = false, ResultMode mode = ResultMode.Normal, bool simple = false, Args...)
        (string name, ref Args args) if (((args.length == 0) || !is(typeof(args[$-1]) == return)) &&
        (mode == ResultMode.Normal || is(Result == ubyte[]))) {
        foreach(T; Args) static assert(isSerializable!(T));
        auto context = new Context();
        auto request = doOutput!(byref, simple)(name, context, args);
        static if (is(Result == void)) {
            doInput!(Variant, mode)(sendAndReceive(request), context, args);
        }
        else {
            return doInput!(Result, mode)(sendAndReceive(request), context, args);
        }
    }
    void invoke(Args...)
    (string name, Args args, void delegate() callback) {
        alias Result = Variant;
        enum mode = ResultMode.Normal;
        enum simple = false;
        mixin(asyncInvoke!(false, false, false));
    }
    void invoke(ResultMode mode = ResultMode.Normal, bool simple = false, Callback, Args...)
    (string name, Args args, Callback callback) if (is(Callback R == void delegate(R)) && (mode == ResultMode.Normal || is(R == ubyte[]))) {
        alias Result = ParameterTypeTuple!callback[0];
        mixin(asyncInvoke!(false, true, false));
    }
    void invoke(bool byref = false, ResultMode mode = ResultMode.Normal, bool simple = false, Result, Args...)
    (string name, Args args, void delegate(Result result, Args args) callback) if (args.length > 0 && (mode == ResultMode.Normal || is(Result == ubyte[]))) {
        mixin(asyncInvoke!(byref, true, true));
    }
    void invoke(bool byref = true, ResultMode mode = ResultMode.Normal, bool simple = false, Result, Args...)
    (string name, ref Args args, void delegate(Result result, ref Args args) callback) if (args.length > 0 && (mode == ResultMode.Normal || is(Result == ubyte[]))) {
        mixin(asyncInvoke!(byref, true, true));
    }
    void invoke(Args...)
    (string name, Args args, void function() callback) {
        alias Result = Variant;
        enum mode = ResultMode.Normal;
        enum simple = false;
        mixin(asyncInvoke!(false, false, false));
    }
    void invoke(ResultMode mode = ResultMode.Normal, bool simple = false, Callback, Args...)
    (string name, Args args, Callback callback) if (is(Callback R == void function(R)) && (mode == ResultMode.Normal || is(R == ubyte[]))) {
        alias Result = ParameterTypeTuple!callback[0];
        mixin(asyncInvoke!(false, true, false));
    }
    void invoke(bool byref = false, ResultMode mode = ResultMode.Normal, bool simple = false, Result, Args...)
    (string name, Args args, void function(Result result, Args args) callback) if (args.length > 0 && (mode == ResultMode.Normal || is(Result == ubyte[]))) {
        mixin(asyncInvoke!(byref, true, true));
    }
    void invoke(bool byref = true, ResultMode mode = ResultMode.Normal, bool simple = false, Result, Args...)
    (string name, ref Args args, void function(Result result, ref Args args) callback) if (args.length > 0 && (mode == ResultMode.Normal || is(Result == ubyte[]))) {
        mixin(asyncInvoke!(byref, true, true));
    }
    @property ref filters() {
        return this._filters;
    }
}
