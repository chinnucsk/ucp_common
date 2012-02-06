-module(ucp_utils).
-author('rafal.galczynski@jtendo.com').
-author('andrzej.trawinski@jtendo.com').
-author('adam.rutkowski@jtendo.com').
-include("ucp_syntax.hrl").
-include("logger.hrl").

-export([
         to_7bit/1,
         encode_sender/1,
         decode_sender/2,
         create_message/3,
         compose_message/2,
         binary_split/2,
         pad_to/2,
         get_next_trn/1,
         get_next_ref/1,
         trn_to_str/1,
         decode_message/1,
         parse_body/2,
         wrap/1,
         encode_reverse/1,
         decode_reverse/1
        ]).

-export([to_hexstr/1,
         hexstr_to_bin/1,
         hexstr_to_list/1]).


%%--------------------------------------------------------------------
%% @doc
%% Function for converting string to 7-bit encoding according to:
%% GSM 03.38 Version 5.3.0
%%
%% @spec to_7bit(String) -> String
%% @end
%%--------------------------------------------------------------------
to_7bit(Str) -> binary:bin_to_list(ucp_7bit:to_7bit(Str)).

%%--------------------------------------------------------------------
%% Function for calculating UCP OAdC field for string and returns list
%%--------------------------------------------------------------------
encode_sender(Sender) ->
    % TODO: detect international number and set OTOA: 1139
    case has_only_digits(Sender) of
        true ->
            {"", Sender};
        false ->
            {"5039", append_length(
                    to_hexstr(to_7bit(ucp_ira:to(ira, Sender))))}
    end.

decode_sender(OTOA, OAdC) ->
    case OTOA of
        "5039" ->
           [_,_|Sender] = OAdC,
           ucp_ira:to(ascii,
               ucp_7bit:from_7bit(hexstr_to_bin(Sender)));
        _Other ->
           OAdC
    end.

create_message(TRN, CmdId, Body) ->
    NewTRN = get_next_trn(TRN),
    Header = #ucp_header{
                  trn = trn_to_str(NewTRN),
                  o_r = "O",
                  ot = CmdId},
    {ok, NewTRN, compose_message(Header, Body)}.

%%--------------------------------------------------------------------
%% Function for composing whole UCP message
%%--------------------------------------------------------------------
compose_message(Header, Body) ->
    HF = rv(Header),
    BF = rv(Body),
    Len = length(ucp_join(HF,BF)) + 3, % 3:for separator and CRC
    LenS = string:right(integer_to_list(Len, 10), 5, $0),
    % Update header with proper len value
    NHF = rv(Header#ucp_header{len = LenS}),
    % Build message
    Message = ucp_join(NHF, BF, append),
    CRC = calculate_crc(Message),
    Message++CRC.

%%--------------------------------------------------------------------
%% Function for appending list length to beginning of the list
%%--------------------------------------------------------------------
append_length(Sender) ->
    sender_len(Sender)++Sender.

sender_len([], Acc) ->
    to_hexstr(Acc);
sender_len([First,_|Rest], Acc) when First == $0->
    sender_len(Rest, Acc+1);
sender_len([_,_|Rest], Acc) ->
    sender_len(Rest, Acc+2).

sender_len(Sender) ->
    sender_len(Sender, 0).

%%--------------------------------------------------------------------
%% Function for getting 8 last significant bits of number
%%--------------------------------------------------------------------
get_8lsb(Integer) ->
    Integer band 255.

%%--------------------------------------------------------------------
%% Function for calculating CRC checksum for UCP Message
%%--------------------------------------------------------------------
calculate_crc(Data) when is_list(Data) ->
    string:right(integer_to_list(get_8lsb(lists:sum(Data)), 16), 2, $0).

%%--------------------------------------------------------------------
%% Function for checking if Char is digit
%%--------------------------------------------------------------------
is_digit(C) when C > 47, C < 58  -> true;
is_digit(_) -> false.

%%--------------------------------------------------------------------
%% Function for checking if String contains only digits
%%--------------------------------------------------------------------
has_only_digits(Str) ->
    lists:all(fun(Elem) ->is_digit(Elem) end, Str).

%%--------------------------------------------------------------------
%% Function for spliting binary into chunks
%%--------------------------------------------------------------------
binary_split(Bin, Size) when is_binary(Bin), is_integer(Size) ->
    case size(Bin) =< Size of
        true ->
            [Bin];
        false ->
            binary_split(Bin, Size, 0, [])
    end.

binary_split(<<>>, _, _, Acc)->
    lists:reverse(Acc);

binary_split(Bin, Size, ChunkNo, Acc)->
    ToProcess = size(Bin) - length(Acc)*Size,
    case ToProcess =< Size of
        true ->
            binary_split(<<>>, Size, ChunkNo+1,
                         [binary:part(Bin, ChunkNo*Size, ToProcess)|Acc]);
        false ->
            binary_split(Bin, Size, ChunkNo+1,
                         [binary:part(Bin, ChunkNo*Size, Size)|Acc])
    end.

pad_to(Width, Binary) ->
     case (Width - size(Binary) rem Width) rem Width of
        0 -> Binary;
        N -> <<Binary/binary, 0:(N*8)>>
     end.

%%--------------------------------------------------------------------
%% Increase with rotate TRN number
%%--------------------------------------------------------------------
get_next_trn(Val) when is_list(Val) ->
    get_next_trn(list_to_integer(Val));
get_next_trn(Val) when is_integer(Val) andalso Val >= ?MAX_MESSAGE_TRN ->
    ?MIN_MESSAGE_TRN;
get_next_trn(Val) when is_integer(Val) ->
    Val + 1.

%%--------------------------------------------------------------------
%% Increase with rotate Ref (Concatenation Reference Number) number
%%--------------------------------------------------------------------
get_next_ref(Val) when is_list(Val) ->
    get_next_ref(list_to_integer(Val));
get_next_ref(Val) when is_integer(Val) andalso Val >= ?MAX_MESSAGE_REF ->
    ?MIN_MESSAGE_REF;
get_next_ref(Val) when is_integer(Val) ->
    Val + 1.

%%--------------------------------------------------------------------
%% Right pad TRN number with zeros
%%--------------------------------------------------------------------
trn_to_str(Val) when is_integer(Val) ->
    string:right(integer_to_list(Val, 10), 2, $0).

%%--------------------------------------------------------------------
%% UCP message decoder
%%--------------------------------------------------------------------
decode_message(Msg = <<?STX, BinHeader:?UCP_HEADER_LEN/binary, _/binary>>) ->
    Len = size(Msg) - 2,
    <<?STX, MsgS:Len/binary, ?ETX, Rest/binary>> = Msg,
    % TODO: handle rest of the message
    case size(Rest) of
        0 ->
            ?SYS_DEBUG("Received UCP message: ~p", [binary:bin_to_list(MsgS)]),
            HeaderList = binary:bin_to_list(BinHeader),
            case ucp_split(HeaderList) of
                [TRN, LEN, OR, OT] ->
                    Header = #ucp_header{trn = TRN, len = LEN, o_r = OR, ot = OT},
                    BodyLen = list_to_integer(LEN) - ?UCP_HEADER_LEN - ?UCP_CHECKSUM_LEN - 2,
                    case Msg of
                        <<?STX, _Header:?UCP_HEADER_LEN/binary, ?UCP_SEPARATOR,
                        BinBody:BodyLen/binary, ?UCP_SEPARATOR,
                        _CheckSum:?UCP_CHECKSUM_LEN/binary, ?ETX>> ->
                            parse_body(Header, binary:bin_to_list(BinBody));
                        _ ->
                            {error, invalid_message}
                    end;
                _ ->
                    {error, invalid_header}
            end;
       _ -> {error, message_too_long}
    end;

decode_message(_) ->
    {error, invalid_message}.

%%--------------------------------------------------------------------
%% Parse UCP operations
%%--------------------------------------------------------------------
parse_body(Header = #ucp_header{ot = OT, o_r = "O"}, Data) ->
    case {OT, ucp_split(Data)} of
        {"31", [ADC, PID]} ->
            Body = #ucp_cmd_31{adc = ADC, pid = PID},
            {ok, {Header, Body}};
        {"31", _} ->
            {error, invalid_command_syntax};
        {"60", [OADC, OTON, ONPI, STYP, PWD, NPWD, VERS, LADC, LTON, LNPI, OPID, RES1]} ->
            Body = #ucp_cmd_60{ oadc = OADC,
                           oton = OTON,
                           onpi = ONPI,
                           styp = STYP,
                           pwd = ucp_ira:to(ascii, PWD),
                           npwd = ucp_ira:to(ascii, NPWD),
                           vers = VERS,
                           ladc = LADC,
                           lton = LTON,
                           lnpi = LNPI,
                           opid = OPID,
                           res1 = RES1 },
            {ok, {Header, Body}};
        {"60", _} ->
            {error, invalid_command_syntax};
        {"51", [ADC, OADC, AC, NRQ, NADC, NT, NPID,
             LRQ, LRAD, LPID, DD, DDT, VP, RPID, SCTS, DST, RSN, DSCTS,
             MT, NB, MSG, MMS, PR, DCS, MCLS, RPI, CPG, RPLY, OTOA, HPLMN,
             XSER, RES4, RES5]} ->
             Body = #ucp_cmd_5x{adc=ADC, oadc=OADC, ac=AC, nrq=NRQ, nadc=NADC,
                          nt=NT, npid=NPID, lrq=LRQ, lrad=LRAD, lpid=LPID,
                          dd=DD, ddt=DDT, vp=VP, rpid=RPID, scts=SCTS,
                          dst=DST, rsn=RSN, dscts=DSCTS, mt=MT, nb=NB,
                          msg=MSG, mms=MMS, pr=PR, dcs=DCS, mcls=MCLS,
                          rpi=RPI, cpg=CPG, rply=RPLY, otoa=OTOA, hplmn=HPLMN,
                          xser=XSER, res4=RES4, res5=RES5},
            {ok, {Header, Body}};
        {"51", _} ->
            {error, invalid_command_syntax};
        {"52", [ADC, OADC, AC, NRQ, NADC, NT, NPID,
             LRQ, LRAD, LPID, DD, DDT, VP, RPID, SCTS, DST, RSN, DSCTS,
             MT, NB, MSG, MMS, PR, DCS, MCLS, RPI, CPG, RPLY, OTOA, HPLMN,
             XSER, RES4, RES5]} ->
             Body = #ucp_cmd_5x{adc=ADC, oadc=OADC, ac=AC, nrq=NRQ, nadc=NADC,
                          nt=NT, npid=NPID, lrq=LRQ, lrad=LRAD, lpid=LPID,
                          dd=DD, ddt=DDT, vp=VP, rpid=RPID, scts=SCTS,
                          dst=DST, rsn=RSN, dscts=DSCTS, mt=MT, nb=NB,
                          msg=MSG, mms=MMS, pr=PR, dcs=DCS, mcls=MCLS,
                          rpi=RPI, cpg=CPG, rply=RPLY, otoa=OTOA, hplmn=HPLMN,
                          xser=XSER, res4=RES4, res5=RES5},
            {ok, {Header, Body}};
        {"52", _} ->
            {error, invalid_command_syntax};
        {"53", [ADC, OADC, AC, NRQ, NADC, NT, NPID,
             LRQ, LRAD, LPID, DD, DDT, VP, RPID, SCTS, DST, RSN, DSCTS,
             MT, NB, MSG, MMS, PR, DCS, MCLS, RPI, CPG, RPLY, OTOA, HPLMN,
             XSER, RES4, RES5]} ->
             Body = #ucp_cmd_5x{adc=ADC, oadc=OADC, ac=AC, nrq=NRQ, nadc=NADC,
                          nt=NT, npid=NPID, lrq=LRQ, lrad=LRAD, lpid=LPID,
                          dd=DD, ddt=DDT, vp=VP, rpid=RPID, scts=SCTS,
                          dst=DST, rsn=RSN, dscts=DSCTS, mt=MT, nb=NB,
                          msg=MSG, mms=MMS, pr=PR, dcs=DCS, mcls=MCLS,
                          rpi=RPI, cpg=CPG, rply=RPLY, otoa=OTOA, hplmn=HPLMN,
                          xser=XSER, res4=RES4, res5=RES5},
            {ok, {Header, Body}};
        {"53", _} ->
            {error, invalid_command_syntax};
        _ ->
            {error, unsupported_operation}
    end;


%%--------------------------------------------------------------------
%% Parse result messages
%%--------------------------------------------------------------------
parse_body(Header = #ucp_header{ot = OT, o_r = "R"}, Data) ->
    case {OT, ucp_split(Data)} of
        {_OT, ["A", SM]} -> % OT: 31, 60
            Body = #ack{sm = SM},
            {ok, {Header, Body}};
        {_OT, ["A", MVP, SM]} -> % OT: 51
            Body = #ack{sm = SM, mvp = MVP},
            {ok, {Header, Body}};
        {_OT, ["N", EC, SM]} -> % OT: 31, 51, 60
            Body = #nack{ec = EC, sm = SM},
            {ok, {Header, Body}};
        _ ->
            {error, unsupported_operation}
    end;

parse_body(_Header, _Body) ->
    {error, unsupported_operation}.


%%--------------------------------------------------------------------
%% Utility functions
%%--------------------------------------------------------------------

wrap(Message) ->
    binary:list_to_bin([?STX, Message, ?ETX]).

rv(Record) when is_tuple(Record) ->
    [_|Vals] = tuple_to_list(Record),
    Vals.

ucp_join(L1, L2) ->
    string:join(L1++L2, [?UCP_SEPARATOR]).
ucp_join(L1, L2, append) ->
    ucp_join(L1,L2) ++ [?UCP_SEPARATOR].

ucp_split(L) ->
    re:split(L, [?UCP_SEPARATOR], [{return,list}]).

%%--------------------------------------------------------------------
%% Hex mangling utils
%%--------------------------------------------------------------------

to_hexstr(Bin) when is_binary(Bin) ->
    to_hexstr(binary_to_list(Bin));

to_hexstr(Int) when is_integer(Int) andalso Int > 255 ->
    to_hexstr(unicode, Int);

to_hexstr(Int) when is_integer(Int) ->
    to_hexstr(ascii, Int);

to_hexstr(L) when is_list(L) ->
    Type = case lists:any(fun(X) when X > 255 ->
                    true;
                   (_) ->
                    false
                   end, L) of
              true -> unicode;
              false -> ascii
          end,
    lists:flatten([to_hexstr(Type, X) || X <- L]).

hexstr_to_bin(H) ->
    <<<<(erlang:list_to_integer([X], 16)):4>> || X <- H>>.

hexstr_to_list(H) ->
    binary_to_list(hexstr_to_bin(H)).

to_hexstr(ascii, Int) when is_integer(Int) ->
    string:right(integer_to_list(Int, 16), 2, $0);

to_hexstr(unicode, Int) when is_integer(Int) ->
    string:right(integer_to_list(Int, 16), 4, $0).

%%--------------------------------------------------------------------
%% Reverse nibble encoding/decoding
%%--------------------------------------------------------------------
encode_reverse(L) ->
    encode_reverse(L, []).

encode_reverse([], Acc) ->
    lists:reverse(Acc);
encode_reverse([A|[]], Acc) ->
    encode_reverse([], [A, $F | Acc]);
encode_reverse([A, B|T], Acc) ->
    encode_reverse(T, [A, B | Acc]).

decode_reverse(L) ->
    decode_reverse(L, []).

decode_reverse([], Acc) ->
    lists:reverse(Acc);
decode_reverse([$F, A], Acc) ->
    decode_reverse([], [A | Acc]);
decode_reverse([A, B|T], Acc) ->
    decode_reverse(T, [A, B | Acc]).

%%--------------------------------------------------------------------
%% Eunit tests
%%--------------------------------------------------------------------

-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

%% just basic assertions to prevent regression

split_join_test() ->
    L = "ABC/DEF/GHI",
    R = ucp_split(L),
    ?assertEqual(["ABC", "DEF", "GHI"], R),
    L2 = ucp_join(R, R),
    ?assertEqual("ABC/DEF/GHI/ABC/DEF/GHI", L2),
    L3 = ucp_join(R, R, append),
    ?assertEqual("ABC/DEF/GHI/ABC/DEF/GHI/", L3),
    R2 = ucp_split(L3),
    ?assertEqual(["ABC", "DEF", "GHI", "ABC", "DEF", "GHI", []], R2),
    R3 = ucp_split("///"),
    ?assertEqual([[],[],[],[]], R3).

rv_test() ->
    A = {foo, bar, baz},
    B = {foo, [bar, {baz}]},
    ?assertEqual([bar, baz], rv(A)),
    ?assertEqual([[bar, {baz}]], rv(B)).

encode_sender_test() ->
    ?assertEqual({"", "1112376382900"}, encode_sender("1112376382900")),
    ?assertEqual({"5039", "106F79D87D2EBBE06C"}, encode_sender("orange.pl")),
    ?assertEqual("orange.pl", decode_sender("5039", "106F79D87D2EBBE06C")),
    ?assertEqual("11112376382900", decode_sender(whatever, "11112376382900")),
    ?assertEqual({"5039", "2721E08854F29A54A854ABB7DA76F77DEECBC5D201"},
        encode_sender("!@#$%^&*()-=+[]{}\\/.,:")),
    ?assertEqual("!@#$%^&*()-=+[]{}\\/.,:", decode_sender("5039",
        "2721E08854F29A54A854ABB7DA76F77DEECBC5D201")).

encode_reverse_test() ->
    ?assertEqual("84214365", encode_reverse("48123456")),
    ?assertEqual("84214365F7", encode_reverse("481234567")).

decode_reverse_test() ->
    ?assertEqual("48123456", decode_reverse("84214365")),
    ?assertEqual("481234567", decode_reverse("84214365F7")).

-endif.
