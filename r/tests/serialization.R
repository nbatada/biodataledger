library(BioDataLedger)
ns <- asNamespace('BioDataLedger')
json <- get('.json',ns); encode <- get('.json_save',ns); obj <- get('.obj',ns)
# Exact bytes retain nulls, array cardinality, object names, escapes and numeric formatting.
values <- list(NULL,list(),obj(),list(NULL),list(obj()),list('x'),list('x','y'),
               obj('quote"'='line\n\t\\',unicode='γδ 日本語',numbers=list(-0,1e-15,1.23456789012345,9007199254740991)),
               obj(extension=obj(null=NULL,array=list(obj(),list(NULL)),empty=obj())))
state <- obj(records=values,history=list(),project=obj(name='synthetic'),state_revision=1L)
first <- encode(state)
stopifnot(identical(first$text,json(state)),identical(encode(state,state,first$cache)$text,json(state)))
# Cache positions compare complete values, including attributes, rather than record IDs.
changed <- state;changed$records <- c(list(obj(revision=2L)),rev(values));changed$history <- list(obj(transaction='new'))
second <- encode(changed,state,first$cache)
stopifnot(identical(second$text,json(changed)))
changed$records <- changed$records[-c(1,3)];changed$history[[1]]$transaction <- NULL
stopifnot(identical(encode(changed,state,first$cache)$text,json(changed)))
positive <- obj(records=list(obj(value=0)),history=list());positive_json <- encode(positive)
negative <- positive;negative$records[[1]]$value <- -0
stopifnot(identical(encode(negative,positive,positive_json$cache)$text,json(negative)))
# Accepted class-specific values always use jsonlite, preserving its existing behavior.
classes <- obj(records=list(obj(date=as.Date('2026-11-04'),factor=factor('a'),matrix=matrix(1:4,2))),history=list())
class_result <- encode(classes)
stopifnot(identical(class_result$text,json(classes)),is.null(class_result$cache$records[[1]]))
ref <- new.env(parent=emptyenv());ref$value <- 1
stopifnot(!get('.json_cacheable',ns)(obj(reference=ref)))
# A failed warm save retains pending edits and the last committed serialization cache.
root <- tempfile('bdl-serialization-');dir.create(root)
p <- ProjectBundle$create('Synthetic serialization',root)
p$record_decision('First','synthetic',list());p$save()
env <- environment(p$save);prior <- get('serialization_cache',env)
p$record_decision('Pending','synthetic',list())
options(BioDataLedger.inject_save_before_rename=TRUE)
failed <- tryCatch({p$save();FALSE},error=function(e) TRUE)
options(BioDataLedger.inject_save_before_rename=NULL)
stopifnot(failed,identical(prior,get('serialization_cache',env)),p$status()$unsaved)
p$save();p$record_decision('Next','synthetic',list());p$save()
loaded <- ProjectBundle$open(root);stopifnot(!loaded$status()$unsaved)
# The exact registry bytes remain the standard serializer's bytes after warm saves.
stopifnot(identical(readChar(file.path(root,'.nb_project_bundle/project.json'),file.info(file.path(root,'.nb_project_bundle/project.json'))$size,useBytes=TRUE),json(get('state',environment(p$save)))))
unlink(root,recursive=TRUE)
