%{
/*
 * Copyright (C) 2014 Tobias Brunner
 * HSR Hochschule fuer Technik Rapperswil
 *
 * This program is free software; you can redistribute it and/or modify it
 * under the terms of the GNU General Public License as published by the
 * Free Software Foundation; either version 2 of the License, or (at your
 * option) any later version.  See <http://www.fsf.org/copyleft/gpl.txt>.
 *
 * This program is distributed in the hope that it will be useful, but
 * WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY
 * or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License
 * for more details.
 */

#include <utils/parser_helper.h>

#include "settings_parser.h"

bool settings_parser_open_next_file(parser_helper_t *ctx);

static void include_files(parser_helper_t *ctx);

%}
%option debug
%option warn

/* use start conditions stack */
%option stack

/* do not declare unneded functions */
%option noinput noyywrap

/* don't use global variables, and interact properly with bison */
%option reentrant bison-bridge

/* maintain the line number */
%option yylineno

/* don't generate a default rule */
%option nodefault

/* prefix function/variable declarations */
%option prefix="settings_parser_"
/* don't change the name of the output file otherwise autotools has issues */
%option outfile="lex.yy.c"

/* type of our extra data */
%option extra-type="parser_helper_t*"

/* state used to scan values */
%x val
/* state used to scan include file patterns */
%x inc
/* state used to scan quoted strings */
%x str

%%

[\t ]*#[^\r\n]*			/* eat comments */
[\t\r ]+				/* eat whitespace */
\n|#.*\n				return NEWLINE; /* also eats comments at the end of a line */

"{"						|
"}"						return yytext[0];

"="						{
	yy_push_state(val, yyscanner);
	return yytext[0];
}

"include"[\t ]+/[^=]	{
	yyextra->string_init(yyextra);
	yy_push_state(inc, yyscanner);
}

"\""					{
	PARSER_DBG1(yyextra, "unexpected string detected");
	return STRING_ERROR;
}

[^#{}="\r\n\t ]+			{
	yylval->s = strdup(yytext);
	return NAME;
}

<val>{
	\r					/* just ignore these */
	[\t ]+
	<<EOF>>				|
	[#}\n]			{
		if (*yytext)
		{
			switch (yytext[0])
			{
				case '\n':
					/* put the newline back to fix the line numbers */
					unput('\n');
					yy_set_bol(0);
					break;
				case '#':
				case '}':
					/* these are parsed outside of this start condition */
					unput(yytext[0]);
					break;
			}
		}
		yy_pop_state(yyscanner);
	}

	"\""					{
		yyextra->string_init(yyextra);
		yy_push_state(str, yyscanner);
	}

	/* same as above, but allow more characters */
	[^#}"\r\n\t ]+			{
		yylval->s = strdup(yytext);
		return NAME;
	}
}

<inc>{
	\r					/* just ignore these */
	/* we allow all characters except #, } and spaces, they can be escaped */
	<<EOF>>				|
	[#}\n\t ]			{
		if (*yytext)
		{
			switch (yytext[0])
			{
				case '\n':
					/* put the newline back to fix the line numbers */
					unput('\n');
					yy_set_bol(0);
					break;
				case '#':
				case '}':
					/* these are parsed outside of this start condition */
					unput(yytext[0]);
					break;
			}
		}
		include_files(yyextra);
		yy_pop_state(yyscanner);
	}
	"\""				{	/* string include */
		yy_push_state(str, yyscanner);
	}
	\\					{
		yyextra->string_add(yyextra, yytext);
	}
	\\["#} ]			{
		yyextra->string_add(yyextra, yytext+1);
	}
	[^"\\#}\r\n\t ]+ {
		yyextra->string_add(yyextra, yytext);
	}
}

<str>{
	\r					/* just ignore these */
	"\""				|
	<<EOF>>				|
	\\					{
		if (!streq(yytext, "\""))
		{
			PARSER_DBG1(yyextra, "unterminated string detected");
			return STRING_ERROR;
		}
		if (yy_top_state(yyscanner) == inc)
		{	/* string include */
			include_files(yyextra);
			yy_pop_state(yyscanner);
			yy_pop_state(yyscanner);
		}
		else
		{
			yy_pop_state(yyscanner);
			yylval->s = yyextra->string_get(yyextra);
			return STRING;
		}
	}

	\\n     yyextra->string_add(yyextra, "\n");
	\\r     yyextra->string_add(yyextra, "\r");
	\\t     yyextra->string_add(yyextra, "\t");
	\\\r?\n /* merge lines that end with escaped EOL characters */
	\\.     yyextra->string_add(yyextra, yytext+1);
	[^\\\r"]+			{
		yyextra->string_add(yyextra, yytext);
	}
}

<<EOF>>					{
	settings_parser_pop_buffer_state(yyscanner);
	if (!settings_parser_open_next_file(yyextra) && !YY_CURRENT_BUFFER)
	{
		yyterminate();
	}
}

%%

/**
 * Open the next file, if any is queued and readable, otherwise returns FALSE.
 */
bool settings_parser_open_next_file(parser_helper_t *ctx)
{
	FILE *file;

	file = ctx->file_next(ctx);
	if (!file)
	{
		return FALSE;
	}

	settings_parser_set_in(file, ctx->scanner);
	settings_parser_push_buffer_state(
			settings_parser__create_buffer(file, YY_BUF_SIZE,
										   ctx->scanner), ctx->scanner);
	return TRUE;
}

/**
 * Assumes that the file pattern to include is currently stored as string on
 * the helper object.
 */
static void include_files(parser_helper_t *ctx)
{
	char *pattern = ctx->string_get(ctx);

	ctx->file_include(ctx, pattern);
	free(pattern);

	settings_parser_open_next_file(ctx);
}

/**
 * Load the given string to be parsed next
 */
void settings_parser_load_string(parser_helper_t *ctx, const char *content)
{
	settings_parser__scan_string(content, ctx->scanner);
}
