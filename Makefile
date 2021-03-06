SHELL           = /bin/bash
AWK            ?= $(shell command -v gawk 2> /dev/null)
CFG            ?= .env

CREATE_SOURCES ?= $(wildcard [1-9]?_*.sql)
TEST_SOURCES   ?= $(wildcard 14_*.sql 9?_*.sql)
UPDATE_SOURCES ?= $(wildcard 1[4-9]_*.sql [3-6]?_*.sql 9?_*.sql)
DROP_SOURCES   ?= $(wildcard 0?_*.sql)
CREATE_OBJECTS ?= $(addprefix build/,$(CREATE_SOURCES))
TEST_OBJECTS   ?= $(addprefix build/,$(TEST_SOURCES))
UPDATE_OBJECTS   ?= $(addprefix build/,$(UPDATE_SOURCES))
DROP_OBJECTS   ?= $(addprefix build/,$(DROP_SOURCES))

PG_CONTAINER   ?= dcape_db_1
DB_USER        ?= dbrpc
SCHEMA         ?= auth
TOOL           ?= psql

-include $(CFG)
export

.PHONY: help build-docker build-psql clean-docker clean-psql docs METHODS.md

# ------------------------------------------------------------------------------

all: help

create: build-dir $(CREATE_OBJECTS)
create: SOURCES=$(CREATE_OBJECTS)
create: make-${TOOL}

update: build-dir $(UPDATE_OBJECTS)
update: SOURCES=$(UPDATE_OBJECTS)
update: make-${TOOL}

test: build-dir $(TEST_OBJECTS)
test: SOURCES = $(TEST_OBJECTS)
test: make-${TOOL}

## Drop database schema
drop: build-dir $(DROP_OBJECTS)
drop: SOURCES=$(DROP_OBJECTS)
drop: make-${TOOL}

recreate: drop create

psql: psql-${TOOL}

## Remove build temp files
clean:
	@rm -f *.out errors.diff

deps:
ifndef AWK
    $(error "gawk is not available, please install it")
endif
	@echo "$(AWK) found."

# ------------------------------------------------------------------------------

docs: METHODS.md

# doc_gen.sh from https://github.com/LeKovr/apitools
METHODS.md:
	@CONFIG=$(CFG) bash doc_gen.sh $$SCHEMA > $@

# ------------------------------------------------------------------------------
# sql file preprocessor performs the following tasks:
# * sql code: replace rows "$_$" with "$_$ /* filename:rownumber */"
# * tests: add commands for .md generation, runtime output and result check

build/%.sql: %.sql
	@echo "$<"
	@src=$< ; \
	if [[ $$src == $${src#9*} ]] ; then \
	  # regular source \
	  echo "\\qecho $<" > $@ ;\
	  $(AWK) '{ print gensub(/(\$$_\$$)($$| +#?)/, "\\1\\2 /* " FILENAME ":" FNR " */ ","g")};' $$src >> $@ ; \
	else \
	  # test file \
	  srcn=$${src%.sql} ; \
	  echo "\\set TEST $$srcn" > $@ ; \
	  echo "\\set TESTOUT build/$$srcn.md" >> $@ ; \
	  cat _test_begin.sql >> $@ ; \
	  $(AWK) '{ gsub(/ *-- *BOT/, "\n\\qecho '\''#  t/'\'':NAME\nSELECT :'\''NAME'\''\n\\set QUIET on\n\\pset t on\n\\g :OUTT\n\\pset t off\n\\set QUIET on"); gsub(/; *-- *EOT/, "\n\\w :OUTW\n\\g :OUTG"); print }' $$src >> $@ ; \
	  echo "\! diff $$srcn.md build/$$srcn.md | tr \"\t\" ' ' > build/errors.diff" >> $@ ; \
	  cat _test_end.sql >> $@ ; \
	fi

build-dir:
	@if [ ! -d build ] ; then mkdir build ; fi

# Load sql via running docker container
# cat used because running docker container has no access to our files
make-docker: docker-wait deps
	tmp_dir=$(shell mktemp -u) ; \
	docker exec -i $$PG_CONTAINER mkdir -p $$tmp_dir/build ; \
	echo "Temp dir: $$tmp_dir" ; \
	docker cp . $$PG_CONTAINER:$$tmp_dir ; \
	ls -1 $(SOURCES) | xargs -n 1 cat | docker exec -i $$PG_CONTAINER bash -c "cd $$tmp_dir && psql -U $$DB_USER \
	  -X -1 -v ON_ERROR_STOP=1 -v SCH=$$SCHEMA -v USER_PASS=$$ADMIN_USER_PASS" ; \
	docker exec -i $$PG_CONTAINER rm -rf $$tmp_dir

# Load sql via local psql
make-psql:
	@ls -1 $(SOURCES) | xargs -n 1 echo "\i" \
	  | psql -d "postgres://$$DB_USER:$$DB_PASS@$$DB_ADDR/$$DB_NAME?sslmode=disable" \
	    -X -1 -v ON_ERROR_STOP=1 -v SCH=$$SCHEMA -v USER_PASS=$$ADMIN_USER_PASS

# Wait for postgresql container start
docker-wait:
	@echo -n "Checking PG is ready..."
	@until [[ `docker inspect -f "{{.State.Health.Status}}" $$PG_CONTAINER` == healthy ]] ; do sleep 1 ; echo -n "." ; done
	@echo "Ok"

create-db: docker-wait
	@docker exec -it $$PG_CONTAINER psql -U postgres -c "CREATE USER \"$$DB_USER\" WITH PASSWORD '$$DB_PASS';" || true
	@docker exec -it $$PG_CONTAINER psql -U postgres -c "CREATE DATABASE \"$$DB_NAME\" OWNER \"$$DB_USER\";" || true
	@docker exec -it $$PG_CONTAINER psql -U postgres -d $$DB_NAME -c "CREATE EXTENSION IF NOT EXISTS pgcrypto;"

# ------------------------------------------------------------------------------

## run psql
psql-psql:
	@psql -d "postgres://$$DB_USER:$$DB_PASS@$$DB_ADDR/$$DB_NAME?sslmode=disable" -v SCH=$$SCHEMA

psql-docker: docker-wait
	@docker exec -ti $$PG_CONTAINER psql -U $$DB_USER

# ------------------------------------------------------------------------------

## List Makefile targets
help:
	@grep -A 1 "^##" Makefile | less

##
## Press 'q' for exit
##
