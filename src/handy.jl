# Handy wrappers to functions defined in api.jl.

"""
    mysql_options(hndl::MySQLHandle, opts)

Set multiple options specified in the dictionary `opts`.  The keys represent the option type,
 for example `MYSQL_OPT_RECONNECT` and the values are the value of the corresponding option.  See `MYSQL_OPT_*` for a list of options.
"""
function mysql_options(hndl, opts)
    for (k, v) in opts
        mysql_options(hndl, k, v)
    end
    nothing
end

function mysql_connect(host::String,
                        user::String,
                        passwd::String,
                        db::String,
                        port::Cuint,
                        unix_socket::String,
                        client_flag; opts = Dict())
    _mysqlptr = C_NULL
    _mysqlptr = mysql_init(_mysqlptr)
    _mysqlptr == C_NULL && throw(MySQLInterfaceError("Failed to initialize MySQL database"))
    mysql_options(_mysqlptr, opts)
    mysqlptr = mysql_real_connect(_mysqlptr, host, user, passwd,
                                  db, port, unix_socket, client_flag)
    mysqlptr == C_NULL && throw(MySQLInternalError(_mysqlptr))
    stmtptr = mysql_stmt_init(mysqlptr)
    stmtptr == C_NULL && throw(MySQLInternalError(mysqlptr))
    return MySQLHandle(mysqlptr, host, user, db, stmtptr)
end

"""
    mysql_connect(host::String, user::String, passwd::String, db::String = ""; port::Int64 = MYSQL_DEFAULT_PORT, socket::String = MYSQL_DEFAULT_SOCKET, opts = Dict())

Connect to a MySQL database.
"""
function mysql_connect(host, user, passwd, db=""; port=MYSQL_DEFAULT_PORT, socket=MYSQL_DEFAULT_SOCKET, opts = Dict())
    return mysql_connect(host, user, passwd, db, convert(Cuint, port),
                         socket, CLIENT_MULTI_STATEMENTS, opts=opts)
end

"""
    mysql_disconnect(hndl::MySQLHandle)

Close a handle to a MySQL database opened by `mysql_connect`.
"""
function mysql_disconnect(hndl)
    hndl.mysqlptr == C_NULL && throw(MySQLInterfaceError("Method called with NULL connection."))
    hndl.stmtptr == C_NULL && throw(MySQLInterfaceError("Method called with NULL statement handle."))
    mysql_stmt_close(hndl.stmtptr)
    mysql_close(hndl.mysqlptr)
    hndl.mysqlptr = C_NULL
    hndl.host = ""
    hndl.user = ""
    hndl.db = ""
    hndl.stmtptr = C_NULL
    nothing
end

function mysql_affected_rows(res::MySQLResult)
    res.resptr == C_NULL && throw(MySQLInterfaceError("Method called with NULL result."))
    ret = mysql_affected_rows(res.resptr)
    ret == typemax(Culong) && throw(MySQLInternalError(res.con))
    return ret
end

function mysql_next_result(hndl::MySQLHandle)
    hndl.mysqlptr == C_NULL && throw(MySQLInterfaceError("Method called with NULL connection."))
    resp = mysql_next_result(hndl.mysqlptr)
    resp > 0 && throw(MySQLInternalError(hndl))
    return resp
end

for func = (:mysql_field_count, :mysql_error, :mysql_insert_id)
    eval(quote
        function ($func)(hndl::MySQLHandle, args...)
            hndl.mysqlptr == C_NULL && throw(MySQLInterfaceError($(string(func)) * " called with NULL connection."))
            return ($func)(hndl.mysqlptr, args...)
        end
    end)
end

"""
    mysql_insert_id(hndl::MySQLHandle) -> Int

Returns the value generated by auto increment column by the previous
insert / update statement.
"""
mysql_insert_id

# wrappers to take MySQLHandle as input as well as check for NULL pointer.
for func = (:mysql_query, :mysql_options)
    eval(quote
        function ($func)(hndl::MySQLHandle, args...)
            hndl.mysqlptr == C_NULL && throw(MySQLInterfaceError($(string(func)) * " called with NULL connection."))
            val = ($func)(hndl.mysqlptr, args...)
            val != 0 && throw(MySQLInternalError(hndl))
            return val
        end
    end)
end

"""
    mysql_query(hndl::MySQLHandle, sql::String)

Executes a SQL statement.  This function does not return query results or number of affected rows.  Please use `mysql_execute` for such purposes.
"""
mysql_query

"""
    mysql_store_result(hndl::MySQLHandle) -> MySQLResult

Returns a `MySQLResult` instance for a query executed with `mysql_query`.
"""
function mysql_store_result(hndl::MySQLHandle)
    hndl.mysqlptr == C_NULL && throw(MySQLInterfaceError("Method called with NULL connection."))
    ptr = mysql_store_result(hndl.mysqlptr)
    ptr == C_NULL && throw(MySQLInternalError(hndl))
    return MySQLResult(hndl, ptr)
end

"""
    mysql_execute(hndl::MySQLHandle, command::String; opformat=MYSQL_DATA_FRAME)

A function for executing queries and getting results.

In the case of multi queries this function returns an array of number of affected
 rows and Tuples. The number of affected rows correspond to the
 non-SELECT queries and the Tuples for the SELECT queries in the
 multi-query.

In the case of non-multi queries this function returns either the number of affected
 rows for non-SELECT queries or a Tuple for SELECT queries.
"""
function mysql_execute(hndl, command)
    hndl.mysqlptr == C_NULL && throw(MySQLInterfaceError("Method called with null connection."))
    mysql_query(hndl.mysqlptr, command) != 0 && throw(MySQLInternalError(hndl))

    data = Any[]

    convfunc = mysql_get_result_as_tuples

    while true
        result = mysql_store_result(hndl.mysqlptr)
        if result != C_NULL # if select query
            retval = convfunc(MySQLResult(hndl, result))
            push!(data, retval)

        elseif mysql_field_count(hndl.mysqlptr) == 0
            push!(data, Int(mysql_affected_rows(hndl.mysqlptr)))
        else
            throw(MySQLInterfaceError("Query expected to produce results but did not."))
        end
        
        status = mysql_next_result(hndl.mysqlptr)
        if status > 0
            throw(MySQLInternalError(hndl))
        elseif status == -1 # if no more results
            break
        end
    end

    if length(data) == 1
        return data[1]
    end
    return data
end

"""
    mysql_execute(hndl::MySQLHandle; opformat=MYSQL_DATA_FRAME)

Execute and get results for prepared statements.  A statement must be prepared with `mysql_stmt_prepare` before calling this function.
"""
function mysql_execute(hndl::MySQLHandle)
    mysql_stmt_execute(hndl)
    naff = mysql_stmt_affected_rows(hndl)
    naff != typemax(typeof(naff)) && return naff        # Not a SELECT query
    return mysql_get_result_as_tuples(hndl)
end

"""
    mysql_execute(hndl::MySQLHandle, typs, values; opformat=MYSQL_DATA_FRAME)

Execute and get results for prepared statements.  A statement must be prepared with `mysql_stmt_prepare` before calling this function.

Parameters are passed to the query in the `values` array.  The corresponding MySQL types must be mentioned in the `typs` array.  See `MYSQL_TYPE_*` for a list of MySQL types.
"""
function mysql_execute(hndl::MySQLHandle, typs, values;
                       opformat=MYSQL_DATA_FRAME)
    bindarr = mysql_bind_array(typs, values)
    mysql_stmt_bind_param(hndl, bindarr)
    return mysql_execute(hndl; opformat=opformat)
end

for func = (:mysql_stmt_num_rows, :mysql_stmt_affected_rows,
            :mysql_stmt_error)
    eval(quote
        function ($func)(hndl::MySQLHandle, args...)
            hndl.stmtptr == C_NULL && throw(MySQLInterfaceError($(string(func)) * " called with NULL statement handle."))
            return ($func)(hndl.stmtptr, args...)
        end
    end)
end

"""
    mysql_stmt_prepare(hndl::MySQLHandle, command::String)

Creates a prepared statement with the `command` SQL string.
"""
function mysql_stmt_prepare(hndl::MySQLHandle, command)
    hndl.stmtptr == C_NULL && throw(MySQLInterfaceError("Method called with NULL statement."))
    val = mysql_stmt_prepare(hndl.stmtptr, command)
    val != 0 && throw(MySQLStatementError(hndl))
    return val
end

function mysql_stmt_execute(hndl::MySQLHandle)
    hndl.stmtptr  == C_NULL && throw(MySQLInterfaceError("Method called with Null statement handle"))
    val = mysql_stmt_execute(hndl.stmtptr)
    val != 0 && throw(MySQLStatementError(hndl))
    return val
end

function mysql_stmt_fetch(hndl::MySQLHandle)
    hndl.stmtptr == C_NULL && throw(MySQLInterfaceError("Method called with NULL statement handle."))
    val = mysql_stmt_fetch(hndl.stmtptr)
    val == 1 && throw(MySQLStatementError(hndl))
    return val
end

function mysql_stmt_bind_result(hndl::MySQLHandle, bindarr::Vector{MYSQL_BIND})
    hndl.stmtptr == C_NULL && throw(MySQLInterfaceError("Method called with NULL statement handle."))
    val = mysql_stmt_bind_result(hndl.stmtptr, pointer(bindarr))
    val != 0 && throw(MySQLStatementError(hndl))
    return val
end

for func = (:mysql_stmt_store_result, :mysql_stmt_bind_param)
    eval(quote
        function ($func)(hndl, args...)
            hndl.stmtptr == C_NULL && throw(MySQLInterfaceError($(string(func)) * " called with NULL statement handle."))
            val = ($func)(hndl.stmtptr, args...)
            val != 0 && throw(MySQLStatementError(hndl))
            return val
        end
    end)
end

for func = (:mysql_num_rows, :mysql_fetch_row)
    eval(quote
        function ($func)(hndl, args...)
            hndl.resptr == C_NULL && throw(MySQLInterfaceError($(string(func)) * " called with NULL result set."))
            return ($func)(hndl.resptr, args...)
        end
    end)
end

"""
Get a `MYSQL_BIND` instance given the mysql type `typ` and a `value`.
"""
mysql_bind_init(typ::MYSQL_TYPE, value) =
    mysql_bind_init(mysql_get_julia_type(typ), typ, value)

mysql_bind_init(jtype::Union{Type{Date}, Type{DateTime}}, typ, value) =
    MYSQL_BIND([convert(MYSQL_TIME, convert(jtype, value))], typ)

mysql_bind_init(::Type{String}, typ, value) = MYSQL_BIND(value, typ)
mysql_bind_init(jtype, typ, value) = MYSQL_BIND([convert(jtype, value)], typ)

"""
Get the binding array for arguments to be passed to prepared statements.

`typs` is an array of `MYSQL_TYPES` and `params` is and array of corresponding values.

Returns an array of `MYSQL_BIND`.
"""
function mysql_bind_array(typs, params)
    length(typs) != length(params) && throw(MySQLInterfaceError("Length of `typs` and `params` must be same."))
    bindarr = MYSQL_BIND[]
    for (typ, val) in zip(typs, params)
        #Is the value one of three different versions of Null?
        if (isdefined(:DataArrays)&&(typeof(val)==DataArrays.NAtype))||(isdefined(:NullableArrays)&&(typeof(val)<:Nullable)&&(val.isnull))||(val==nothing) 
            push!(bindarr, mysql_bind_init(MYSQL_TYPE_NULL, "NULL"))
        else
            push!(bindarr, mysql_bind_init(typ, val)) #Otherwise
        end 
    end
    return bindarr
end

"""
    mysql_metadata(hndl::MySQLResult) -> MySQLMetadata

Get result metadata from a `MySQLResult` instance.
"""
function mysql_metadata(result::MySQLResult)
    result.resptr == C_NULL && throw(MySQLInterfaceError("Method called with null result set."))
    return MySQLMetadata(mysql_metadata(result.resptr))
end

"""
    mysql_metadata(hndl::MySQLHandle) -> MySQLMetadata

Get result metadata for a query.  The query must be prepared with `mysql_stmt_prepare` before calling this function.
"""
function mysql_metadata(hndl::MySQLHandle)
    hndl.stmtptr == C_NULL && throw(MySQLInterfaceError("Method called with null statement pointer."))
    return MySQLMetadata(mysql_metadata(hndl.stmtptr))
end

"""
    mysql_escape(hndl::MySQLHandle, str::String) -> String

Escapes a string using `mysql_real_escape_string()`, returns the escaped string.
"""
function mysql_escape(hndl::MySQLHandle, str::String)
    output = Vector{UInt8}(length(str)*2 + 1)
    output_len = mysql_real_escape_string(hndl.mysqlptr, output, str, UInt64(length(str)))
    if output_len == typemax(Cuint)
        throw(MySQLInternalError(hndl))
    end
    return String(output[1:output_len])
end

export mysql_options, mysql_connect, mysql_disconnect, mysql_execute,
       mysql_insert_id, mysql_store_result, mysql_metadata, mysql_query,
       mysql_stmt_prepare, mysql_escape
