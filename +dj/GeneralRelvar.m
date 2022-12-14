% dj.GeneralRelvar - a relational variable supporting relational operators.
% General relvars can be base relvars (associated with a table) or derived
% relvars constructed from other relvars by relational operators.

classdef GeneralRelvar < matlab.mixin.Copyable
    
    properties(Dependent, SetAccess=private)
        sql          % sql expression
        primaryKey   % primary key attribute names
        nonKeyFields % non-key attribute names
        header       % attributes and their properties
    end
    
    properties(SetAccess=private, GetAccess=public)
        restrictions = {} % list of restrictions applied to operator output
    end
    
    properties(SetAccess=private, GetAccess=protected)
        conn              % connection object
        operator          % node type: table, join, or pro
        operands = {}     % list of operands
    end
    
    methods
        function self = init(self, operator, operands, restrictions)
            self.operator = operator;
            if nargin>=3
                self.operands = operands;
            end
            if nargin>=4
                self.restrictions = restrictions;
            end
        end
        
        function conn = get.conn(self)
            if isempty(self.conn)
                self.conn = self.getConn;
            end
            conn = self.conn;
        end
        
        function header = get.header(self)
            header = self.compile;
        end
        
        function s = get.sql(self)
            [~, s] = self.compile;
        end
        
        function names = get.primaryKey(self)
            names = self.header.primaryKey;
        end
        
        function names = get.nonKeyFields(self)
            names = self.header.dependentFields;
        end
        
        function clause = whereClause(self)
            % public where clause
            if isempty(self.restrictions)
                clause = '';
            else
                clause = sprintf(' WHERE %s', makeWhereClause(self.header, self.restrictions));
            end
        end
        
        function display(self)
            % dj.GeneralRelvar/display - display the contents of the relation.
            % Only non-blob attributes of the first several tuples are shown.
            % The total number of tuples is printed at the end.
            nTuples = 0;
            fprintf('\nObject %s\n\n',class(self))
            s = sprintf(', %s', self.primaryKey{:});
            fprintf('Primary key: %s\n', s(2:end))
            if isempty(self.nonKeyFields)
                fprintf 'No dependent attributes'
            else
                s = sprintf(', %s',self.nonKeyFields{:});
                fprintf('Dependent attributes: %s', s(2:end))
            end
            fprintf '\n\n Contents: \n'
            tic
            if self.exists
                % print header
                header = self.header;
                ix = find( ~[header.attributes.isBlob] );  % header to display
                fprintf('  %16.16s', header.attributes(ix).name)
                fprintf \n
                maxRows = 12;
                tuples = self.fetch(header.attributes(ix).name, sprintf('LIMIT %d', maxRows+1));
                nTuples = max(self.count, length(tuples));
                
                % print rows
                for s = tuples(1:min(end,maxRows))'
                    for iField = ix
                        v = s.(header.attributes(iField).name);
                        if isnumeric(v)
                            if ismember(class(v),{'double','single'})
                                fprintf('  %16g',v)
                            else
                                fprintf('  %16d',v)
                            end
                        else
                            fprintf('  %16.16s',v)
                        end
                    end
                    fprintf \n
                end
                if nTuples > maxRows
                    for iField = ix
                        fprintf('  %16s','...')
                    end
                    fprintf \n
                end
            end
            
            % print the total number of tuples
            fprintf('%d tuples (%.3g s)\n\n', nTuples, toc)
        end
        
        function view(self, varargin)
            % dj.Relvar/view - view the data in speadsheet form. Blobs are omitted.
            % Additional arguments are forwarded to fetch(), e.g. for ORDER BY
            % and LIMIT clauses.
            if ~self.exists
                disp 'empty relation'
            else
                columns = {self.header.attributes.name};
                sel = 1:length(columns);
                if ~isempty(self.header.blobNames)
                    warning 'excluding blobs from the view'
                    columns = columns(~[self.header.attributes.isBlob]);
                end
                
                % specify table header
                columnName = columns;
                for iCol = 1:length(columns)
                    if self.header.attributes(iCol).iskey
                        columnName{iCol} = ['<html><b><font color="black">' columnName{iCol} '</b></font></html>'];
                    else
                        columnName{iCol} = ['<html><font color="blue">' columnName{iCol} '</font></html>'];
                    end
                end
                format = cell(1,length(columns));
                format([self.header.attributes(sel).isString]) = {'char'};
                format([self.header.attributes(sel).isNumeric]) = {'numeric'};
                
                % display table
                data = fetch(self, columns{:}, varargin{:});
                hfig = figure('Units', 'normalized', 'Position', [0.1 0.1 0.5 0.4], ...
                    'MenuBar', 'none');
                uitable(hfig, 'Units', 'normalized', 'Position', [0.0 0.0 1.0 1.0], ...
                    'ColumnName', columnName, 'ColumnEditable', false(1,length(columns)), ...
                    'ColumnFormat', format, 'Data', struct2cell(data)');
            end
        end
        
        function clip(self)
            % dj.GeneralRelvar/clip - copy into clipboard the matlab code to re-generate
            % the contents of the relation. Only scalar numeric or string values are allowed.
            % This function may be useful for creating matlab code that fills a table with values.
            %
            % USAGE:
            %    r.clip
            
            str = dj.struct.makeCode(self.fetch('*'));
            clc, disp(str)
            clipboard('copy', str)
            fprintf '\n *** in clipboard *** \n\n'
        end
        
        %%%%%%%%%%%%%%%%%% FETCHING DATA %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
        
        function yes = exists(self)
            % dj.GeneralRelvar/exists - a fast check whether the relvar
            % contains any tuples
            [~, sql] = self.compile(3);
            yes = self.conn.query(sprintf('SELECT EXISTS(SELECT 1 FROM %s LIMIT 1) as yes', sql));
            yes = logical(yes.yes);
        end
        
        function n = count(self)
            % dj.GeneralRelvar/count - the number of tuples in the relation.
            [~, sql] = self.compile(3);
            n = self.conn.query(sprintf('SELECT count(*) as n FROM %s', sql));
            n = double(n.n);
        end
        
        function [ret,keys] = fetch(self, varargin)
            % dj.GeneralRelvar/fetch retrieve data from a relation as a struct array
            % SYNTAX:
            %    s = self.fetch       % retrieve primary key attributes only
            %    s = self.fetch('*')  % retrieve all attributes
            %    s = self.fetch('attr1','attr2',...) - retrieve primary key
            %       attributes and additional listed attributes.
            %
            % The specification of attributes 'attri' follows the same
            % conventions as in dj.GeneralRelvar.pro, including renamed
            % attributed, and computed arguments.  In particular, if the second
            % input argument is another relvar, the computed arguments can
            % include summary operations on the header of the second relvar.
            %
            % For example:
            %   s = R.fetch(Q, 'count(*)->n');
            % Here s(i).n will contain the number of tuples in Q matching
            % the ith tuple in R.
            %
            % If the last input argument is begins with 'ORDER BY' or 'LIMIT',
            % it is not interpreted as an attribute specifier and is passed
            % on to the SQL statement. This allows sorting the result or
            % selecting a subset of tuples.
            %
            % For example:
            %    s = R.fetch('*', 'ORDER BY field1,field2');    % sort the result by field1
            %    s = R.fetch('*', 'LIMIT 100 OFFSET 200')  % read tuples 200-299
            %    s = R.fetch('*', 'ORDER BY field1 DESC, field 2  LIMIT 100');
            %
            % See also dj.Relvar.pro, dj.Relvar/fetch1, dj.Relvar/fetchn
            
            [limit, args] = makeLimitClause(varargin{:});
            self = self.pro(args{:});
            [header, sql] = self.compile;
            ret = self.conn.query(sprintf('SELECT %s FROM %s%s', ...
                header.sql, sql, limit));
            ret = dj.struct.fromFields(ret);
            
            if nargout>1
                % return primary key structure array
                keys = dj.struct.pro(ret,self.primaryKey{:});
            end
        end
        
        function varargout = fetch1(self, varargin)
            % dj.GeneralRelvar/fetch1 same as dj.Relvat/fetch but each field is
            % retrieved into a separate output variable.
            % Use fetch1 when you know that the relvar contains exactly one tuple.
            % The attribute list is specified the same way as in
            % dj.GeneralRelvar/fetch but wildcards '*' are not allowed.
            % The number of specified attributes must exactly match the number
            % of output arguments.
            %
            % Examples:
            %    v1 = R.fetch1('attr1');
            %    [v1,v2,qn] = R.fetch1(Q,'attr1','attr2','count(*)->n')
            %
            % See also dj.Relvar.fetch, dj.Relvar/fetchn, dj.Relvar/pro
            
            % validate input
            [~, args] = makeLimitClause(varargin{:});
            args = args(cellfun(@ischar, args)); % attribute specifiers
            
            assert(nargout==length(args) || (nargout==0 && length(args)==1), ...
                'The number of fetch1() outputs must match the number of requested attributes')
            assert(~isempty(args), 'insufficient inputs')
            assert(~any(strcmp(args,'*')), '"*" is not allowed in fetch1()')
            
            s = self.fetch(varargin{:});
            assert(isscalar(s), 'fetch1 can only retrieve a single existing tuple.')
            
            % copy into output arguments
            varargout = cell(length(args));
            for iArg=1:length(args)
                name = regexp(args{iArg}, '(\w+)\s*$', 'tokens');
                varargout{iArg} = s.(name{1}{1});
            end
        end
        
        function varargout = fetchn(self, varargin)
            % dj.GeneralRelvar/fetchn same as dj.GeneralRelvar/fetch1 but can fetch
            % values from multiple tuples.  Unlike fetch1, string and
            % blob values are retrieved as matlab cells.
            %
            % SYNTAX:
            % [f1, ..., fn] = rel.fetchn('field1',...,'fieldn')
            %
            % You may also obtain the primary key values (as a structure
            % array) that match the retrieved field values.
            %
            % [f1, ..., fn, keys] = rel.fetchn('field1',...,'fieldn')
            %
            % See also dj.Relvar/fetch1, dj.Relvar/fetch, dj.Relvar/pro
            
            [limit, args] = makeLimitClause(varargin{:});
            specs = args(cellfun(@ischar, args)); % attribute specifiers
            returnKey = nargout==length(specs)+1;
            assert(returnKey || (nargout==length(specs) || (nargout==0 && length(specs)==1)), ...
                'The number of fetchn() outputs must match the number of requested attributes')
            assert(~isempty(specs),'insufficient inputs')
            assert(~any(strcmp(specs,'*')), '"*" is not allowed in fetchn()')
            
            % submit query
            self = self.pro(args{:});  % this copies the object, so now it's a different self
            [header, sql] = self.compile;
            ret = self.conn.query(sprintf('SELECT %s FROM %s%s%s',...
                header.sql, sql, limit));
            
            % copy into output arguments
            varargout = cell(length(specs));
            for iArg=1:length(specs)
                % if renamed, use the renamed attribute
                name = regexp(specs{iArg}, '(\w+)\s*$', 'tokens');
                varargout{iArg} = ret.(name{1}{1});
            end
            
            if returnKey
                varargout{length(specs)+1} = dj.struct.fromFields(dj.struct.pro(ret, self.primaryKey{:}));
            end
        end
        
        function export(self, outfilePrefix, mbytesPerChunk)
            % dj.GeneralRelvar/export -- export the contents of the relation into and a .m file
            % The data are split into chunks according to mbytesPerChunk.
            %
            % See also dj.Relvar/import
            
            if nargin<2
                outfilePrefix = './temp';
            end
            if nargin<3
                mbytesPerChunk = 50;
            end
            tuplesPerChunk = 1;
            
            % enclose in transaction to ensure that LIMIT and OFFSET work correctly
            self.conn.startTransaction
            
            savedTuples = 0;
            savedMegaBytes = 0;
            total = self.count;
            fileNumber = 0;
            while savedTuples < total
                while true
                    tuples = self.fetch('*',sprintf('LIMIT %u OFFSET %u', tuplesPerChunk, savedTuples));
                    mbytes = sizeMB(tuples);
                    if mbytes > 0.5*mbytesPerChunk || numel(tuples) + savedTuples >= total
                        break
                    end
                    tuplesPerChunk = tuplesPerChunk*2;
                end
                fname = sprintf('%s-%04d.mat', outfilePrefix, fileNumber);
                save(fname, 'tuples')
                savedMegaBytes = savedMegaBytes + mbytes;
                savedTuples = savedTuples + numel(tuples);
                tuplesPerChunk = ceil(mbytesPerChunk/savedMegaBytes*savedTuples);                
                fprintf('file %s.  Tuples: [%4u/%d]  Total MB: %6.1f\n', fname, savedTuples, total, savedMegaBytes)
                fileNumber = fileNumber + 1;
            end
            
            self.conn.cancelTransaction
            
            function mbytes = sizeMB(variable) %#ok<INUSD>
                mbytes = whos('variable');
                mbytes = mbytes.bytes/1024/1024;
            end
            
        end
        
        
        %%%%%%%%%%%%%%%%%%  RELATIONAL OPERATORS %%%%%%%%%%%%%%%%%%%%%%%%%%
        function restrict(self, varargin)
            % dj.GeneralRelvar/restrict - relational restriction in place
            % Restrictions may be provided as separate arguments or a
            % single cell array.
            % Restrictions may include sql expressions, other relvars, or
            % structure arrays.
            % Including the word 'not' in the restriction list negates one
            % restriction that follows immediately.
            % All conditions must be true for a tuple to pass.
            %
            % Examples:
            %    rel.restrict('session_date>2012-01-01', 'not', struct('anesthesia', 'urethane'))
            %    rel2.restrict(rel)    % all tuples in rel2 that at least on tuple in rel
            
            for arg = varargin
                if iscell(arg{1})
                    self.restrict(arg{1}{:})
                else
                    self.restrictions = [self.restrictions arg(1)];
                end
            end
        end
        
        function ret = and(self, arg)
            % dj.GeneralRelvar/and - relational restriction
            %
            % R1 & cond  yeilds a relation containing all the tuples in R1
            % that match the condition cond. The condition cond could be an
            % structure array, another relation, or an sql boolean
            % expression.
            %
            % Examples:
            %   tp.Scans & struct('mouse_id',3, 'scannum', 4);
            %   tp.Scans & 'lens=10'
            %   tp.Mice & (tp.Scans & 'lens=10')
            ret = self.copy;
            ret.restrict(arg)
        end
        
        function ret = or(self, arg)
            % the relational union operator.
            %
            % arg can be another relvar, a string condition, or a structure array of tuples.
            %
            % The result will be a special kind of relvar that can only be used
            % as an argument in another restriction operator. It cannot be
            % queried on its own.
            %
            % For example:
            %   B | C   cannot be used on its own, but:
            %   A & (B | C) returns all tuples in A that have matching tuples in B or C.
            %   A - (B | C) returns all tuples in A that have no matching tuples in B or C.
            %
            % Warning:
            %  ~A  does not produce a valid relation by itself. Negation is
            %  only valid when applied to a restricing relvar.
            
            if ~strcmp(self.operator, 'union')
                operandList = {self};
            else
                operandList = self.operands;
            end
            
            % expand recursive unions
            if ~isa(arg, 'dj.GeneralRelvar') || ~strcmp(arg.operator, 'union')
                operandList = [operandList {arg}];
            else
                operandList = [operandList arg.operands];
            end
            ret = init(dj.GeneralRelvar, 'union', operandList);
        end
        
        function ret = not(self)
            %  dj.Relvar/not - negation operator.
            %  A & ~B   is equivalent to  A - B
            % But here is an example where minus could not be used.
            %  A & (B & cond | ~B)    % -- if B has matching tuples, also apply cond.
            if strcmp(self.operator, 'not')
                % negation cancels negation
                ret = self.operands{1};
            else
                ret = init(dj.GeneralRelvar, 'not', {self});
            end
        end
        
        function ret = minus(self, arg)
            % dj.GeneralRelvar/minus -- relational antijoin
            if iscell(arg)
                throwAsCaller(MException('DataJoint:invalidOperator',...
                    'Antijoin only accepts single restrictions'))
            end
            ret = self.copy;
            ret.restrict('not', arg)
        end
        
        function ret = pro(self, varargin)
            % dj.GeneralRelvar/pro - relational operators that modify the relvar's header:
            % project, rename, extend, and aggregate.
            %
            % SYNTAX:
            %   r = rel.pro(attr1, ..., attrn)
            %   r = rel.pro(otherRel, attr1, ..., attrn)
            %
            % INPUTS:
            %    'attr1',...,'attrn' is a comma-separated string of attributes.
            %    otherRel is another relvar for the aggregate operator
            %
            % The result will return another relation with the same number of tuples
            % with modified attributes. Primary key attributes are included implicitly
            % and cannot be excluded. Thus pro(rel) simply strips all non-key header.
            %
            % Project: To include an attribute, add its name to the attribute list.
            %
            % Rename: To rename an attribute, list it in the form 'old_name->new_name'.
            % Add '*' to the attribute list to add all the other attributes besides the
            % renamed ones.
            %
            % Extend: To compute a new attribute, list it as 'expression->new_name', e.g.
            % 'datediff(exp_date,now())->days_ago'. The computed expressions may use SQL
            % operators and functions.
            %
            % Aggregate: When the second input is another relvar, the computed
            % expressions may include aggregation functions on attributes of the
            % other relvar: max, min, sum, avg, variance, std, and count.
            %
            % EXAMPLES:
            %   Construct relation r2 containing only the primary keys of r1:
            %   >> r2 = r1.pro();
            %
            %   Construct relation r3 which contains values for 'operator'
            %   and 'anesthesia' for every tuple in r1:
            %   >> r3 = r1.pro('operator','anesthesia');
            %
            %   Rename attribute 'anesthesia' to 'anesth' in relation r1:
            %   >> r1 = r1.pro('*','anesthesia->anesth');
            %
            %   Add field mouse_age to relation r1 that has the field mouse_dob:
            %   >> r1 = r1.pro('*','datediff(now(),mouse_dob)->mouse_age');
            %
            %   Add field 'n' which contains the count of matching tuples in r2
            %   for every tuple in r1. Also add field 'avga' which contains the
            %   average value of field 'a' in r2.
            %   >> r1 = r1.pro(r2,'count(*)->n','avg(a)->avga');
            %
            % See also: dj.Relvar/fetch
            if nargin>2 && isa(varargin{1}, 'dj.GeneralRelvar')
                % if the first argument is a relvar, perform aggregate operator
                op = 'aggregate';
                arg = varargin(1);
                params = varargin(2:end);
            else
                op = 'pro';
                arg = [];
                params = varargin;
            end
            
            if ~iscellstr(params)
                throwAsCaller(MException('DataJoint:invalidOperotor', ...
                    'pro() requires a list of strings as attribute args'))
            end
            
            ret = init(dj.GeneralRelvar, op, [{self} arg params]);
        end
        
        function ret = mtimes(self, arg)
            % dj.GeneralRelvar/mtimes - relational natural join.
            %
            % SYNTAX:
            %   R3=R1*R2
            %
            % The result will contain all matching combinations of tuples
            % in R1 and tuples in R2. Two tuples make a matching
            % combination if their commonly named attributes contain the
            % same values.
            % To control on which attributes the join performed, individual
            % attributes of the arguments may be renamed using dj.Relvar/pro.
            % Blobs and nullable attributes should not be joined on.
            % To prevent an attribute from being joined on, rename it using
            % dj.GeneralRelvar/pro's rename syntax.
            %
            % See also dj.Relvar/pro, dj.Relvar/fetch
            if ~isa(arg, 'dj.GeneralRelvar')
                throwAsCaller(MException('DataJoint:invalidOperotor', ...
                    'dj.GeneralRelvar/mtimes requires another relvar as operand'))
            end
            ret = init(dj.GeneralRelvar, 'join', {self arg});
        end        
        
        function ret = pair(self, varargin)
            % dj.GeneralRelvar/pair - a natural join with itself with some
            % attributes renamed.
            % This facilitates a common use case when pairs of tuples from the
            % relation need to be examined.
            
            renamedAttrs1 = cellfun(@(s) sprintf('%s->%s1',s,s), varargin,'uni',false);
            renamedAttrs2 = cellfun(@(s) sprintf('%s->%s2',s,s), varargin,'uni',false);
            ret = self.pro(renamedAttrs1{:})*self.pro(renamedAttrs2{:});
        end
        
        
        %%%%% DEPRECATED RELATIIONAL OPERATORS (for backward compatibility)
        function ret = times(self, arg)
            warning 'The relational operator .* (semijoin) will be removed in a future release.  Please use & instead.'
            ret = self & arg;
        end
        function ret = rdivide(self, arg)
            warning 'The relational operator / (antijoin) will be removed in a future release.  Please use - instead.'
            ret = self - arg;
        end
        function ret = plus(self, arg)
            warning 'The relational operator + (union) will be removed in a future release.  Please use | instead'
            ret = self | arg;
        end
        
        function ret = show(self)
            % dj.GeneralRelvar/show - show the relation's header information.
            % Foreign keys and indexes are not shown.
            
            str = '';
            %
            % list primary key fields
            keyFields = self.header.primaryKey;
            
            % additional primary attributes
            for i=find(ismember(self.header.names, keyFields))
                comment = self.header.attributes(i).comment;
                if self.header.attributes(i).isautoincrement
                    autoIncrement = 'AUTO_INCREMENT';
                else
                    autoIncrement = '';
                end
                str = sprintf('%s\n%-40s # %s', str, ...
                    sprintf('%-16s: %s %s', self.header.attributes(i).name, ...
                    self.header.attributes(i).type, autoIncrement), comment);
            end
            
            % dividing line
            str = sprintf('%s\n---', str);
            
            % list dependent attributes
            dependentFields = self.header.dependentFields;
            
            % list remaining attributes
            for i=find(ismember(self.header.names, dependentFields))
                attr = self.header.attributes(i);
                default = attr.default;
                if attr.isnullable
                    default = '=null';
                elseif ~isempty(default)
                    if attr.isNumeric || any(strcmp(default,dj.Table.mysql_constants))
                        default = ['=' default]; %#ok<AGROW>
                    else
                        default = ['="' default '"']; %#ok<AGROW>
                    end
                end
                if attr.isautoincrement
                    autoIncrement = 'AUTO_INCREMENT';
                else
                    autoIncrement = '';
                end
                str = sprintf('%s\n%-60s# %s', str, ...
                    sprintf('%-28s: %s', [attr.name default], ...
                    [attr.type ' ' autoIncrement]), attr.comment);
            end
            str = sprintf('%s\n', str);
            
            if nargout
                ret = str;
            else
                disp(str)
            end
        end
    end
    
    
    %%%%%%%%%%%%%%% PRIVATE HELPER FUNCTIONS %%%%%%%%%%%%%%%%%%%%%
    methods(Access = private)
        
        function conn = getConn(self)
            % get reference to the connection object from the first table
            if strcmp(self.operator, 'table')
                conn = self.operands{1}.schema.conn;
            else
                conn = self.operands{1}.getConn;
            end
        end
        
        function [header, sql] = compile(self, enclose)
            % compile the query tree into an SQL expression
            % OUTPUTS:
            %   sql =   "... [WHERE ...] [GROUP BY (...)]'
            %   header = structure array with attribute properties
            %
            % The input argument enclose controls whether the statement
            % must be enclosed in parentheses:
            %   0 - don't enclose
            %   1 - enclose only if some attributes are aliased
            %   2 - enclose if anything but a simple table
            %   3 - enclose if is an aggregate (has a GROUP BY clause)
            % Of course, we could simply always enclose subexpressions in
            % parentheses, but we try to keep SQL expressions as simple as
            % possible.
            
            persistent aliasCount
            if isempty(aliasCount)
                aliasCount = 0;
            end
            aliasCount = aliasCount + 1;
            if nargin<2
                enclose = 0;
            end
            
            % apply relational operators recursively
            switch self.operator
                case 'union'
                    throwAsCaller(MException('DataJoint:invalidOperator', ...
                        'The union operator must be used in a restriction'))
                    
                case 'not'
                    throwAsCaller(MException('DataJoint:invalidOperator', ...
                        'The NOT operator must be used in a restriction'))
                    
                case 'table'  % terminal node
                    tab = self.operands{1};
                    header = derive(tab.tableHeader);
                    sql = tab.fullTableName;
                    
                case 'pro'
                    [header, sql] = compile(self.operands{1},1);
                    header.project(self.operands(2:end));
                    
                case 'aggregate'
                    [header, sql] = compile(self.operands{1},2);
                    [header2, sql2] = compile(self.operands{2},2);
                    commonBlobs = intersect(header.blobNames, header2.blobNames);
                    assert(isempty(commonBlobs), 'join cannot be done on blob attributes')
                    pkey = sprintf(',`%s`', header.primaryKey{:});
                    sql = sprintf('%s NATURAL JOIN %s GROUP BY %s', sql, sql2, pkey(2:end));
                    header.project(self.operands(3:end));
                    assert(~all(arrayfun(@(x) isempty(x.alias), header.attributes)),...
                        'Aggregate operators must define at least one computation')
                    
                case 'join'
                    [header1, sql1] = compile(self.operands{1},2);
                    [header2, sql2] = compile(self.operands{2},2);
                    sql = sprintf('%s NATURAL JOIN %s', sql1, sql2);
                    header = join(header1,header2);
                    clear header1 header2 sql1 sql2
                    
                otherwise
                    error 'unknown relational operator'
            end
            
            % apply restrictions
            if ~isempty(self.restrictions)
                % clear aliases and enclose
                if header.hasAliases
                    sql = sprintf('(SELECT %s FROM %s) as `$s%x`', header.sql, sql, aliasCount);
                    header.stripAliases;
                end
                % add WHERE clause
                sql = sprintf('%s%s', sql);
                whereClause = makeWhereClause(header, self.restrictions);
                if ~isempty(whereClause)
                    sql = sprintf('%s WHERE %s', sql, whereClause);
                end
            end
            
            % enclose in parentheses if necessary
            if enclose==1 && header.hasAliases ...
                    || enclose==2 && (~ismember(self.operator, {'table', 'join'}) || ~isempty(self.restrictions)) ...
                    || enclose==3 && strcmp(self.operator, 'aggregate')
                sql = sprintf('(SELECT %s FROM %s) AS `$a%x`', header.sql, sql, aliasCount);
                header.stripAliases;
            end
        end
    end
end


function clause = makeWhereClause(header, restrictions)
% make the where clause from self.restrictions
persistent aliasCount
if isempty(aliasCount)
    aliasCount = 0;
else
    aliasCount = aliasCount + 1;
end

assert(all(arrayfun(@(x) isempty(x.alias), header.attributes)), ...
    'aliases must be resolved before restriction')

clause = '';
not = '';

for arg = restrictions
    cond = arg{1};
    switch true
        case isa(cond, 'dj.GeneralRelvar') && strcmp(cond.operator, 'union')
            % union
            s = cellfun(@(x) makeWhereClause(header, {x}), cond.operands, 'UniformOutput', false);
            assert(~isempty(s))
            s = sprintf('(%s) OR ', s{:});
            clause = sprintf('%s AND %s(%s)', clause, not, s(1:end-4));  % strip trailing " OR "
            
        case isa(cond, 'dj.GeneralRelvar') && strcmp(cond.operator, 'not')
            clause = sprintf('%s AND NOT(%s)', clause, ...
                makeWhereClause(header, cond.operands));
            
        case ischar(cond) && strcmpi(cond,'NOT')
            % negation of the next condition
            not = 'NOT ';
            continue
            
        case ischar(cond) && ~strcmpi(cond, 'NOT')
            % SQL condition
            clause = sprintf('%s AND %s(%s)', clause, not, cond);
            
        case isstruct(cond)
            % restriction by a
            cond = dj.struct.pro(cond, header.names{:}); % project onto common attributes
            if isempty(fieldnames(cond))
                % restrictor has no common attributes:
                %    semijoin leaves relation unchanged.
                %    antijoin returns the empty relation.
                if ~isempty(not)
                    clause = ' AND FALSE';
                end
            else
                if ~isempty(cond)
                    % normal restricton
                    clause = sprintf('%s AND %s(%s)', clause, not, struct2cond(cond, header));
                else
                    if isempty(cond)
                        % restrictor has common attributes but is empty:
                        %     semijoin makes the empty relation
                        %     antijoin leavs relation unchanged
                        if isempty(not)
                            clause = ' AND FALSE';
                        end
                    end
                end
            end
            
        case isa(cond, 'dj.GeneralRelvar')
            % semijoin or antijoin
            [condHeader, condSQL] = cond.compile;
            
            % isolate previous projection (if not already)
            if ismember(cond.operator, {'pro','aggregate'}) && isempty(cond.restrictions) && ...
                    ~all(cellfun(@isempty, {cond.header.attributes.alias}))
                condSQL = sprintf('(SELECT %s FROM %s) as `$u%x`', ...
                    condHeader.sql, condSQL, aliasCount);
            end
            
            % common attributes for matching. Blobs are not included
            commonAttrs = intersect(header.notBlobs, condHeader.notBlobs);
            if isempty(commonAttrs)
                % no common attributes. Semijoin = original relation, antijoin = empty relation
                if ~isempty(not)
                    clause = ' AND FALSE';
                end
            else
                % make semijoin or antijoin clause
                commonAttrs = sprintf( ',`%s`', commonAttrs{:});
                commonAttrs = commonAttrs(2:end);
                clause = sprintf('%s AND ((%s) %s IN (SELECT %s FROM %s))',...
                    clause, commonAttrs, not, commonAttrs, condSQL);
            end
    end
    not = '';
end
if length(clause)>6
    clause = clause(6:end); % strip " AND "
end
end


function cond = struct2cond(keys, header)
% convert the structure array into an SQL condition
n = length(keys);
assert(n>=1)
if n>512
    warning('DataJoint:longCondition', ...
        'consider replacing the long array of keys with a more succinct condition')
end
cond = '';
for key = keys(:)'
    cond = sprintf('%s OR (%s)', cond, makeCond(key));
end
cond = cond(min(end,5):end);  % strip " OR "

    function subcond = makeCond(key)
        subcond = '';
        for field = fieldnames(key)'
            value = key.(field{1});
            attr = header.byName(field{1});
            assert(~attr.isBlob, 'The key must not include blob header.')
            if attr.isString
                assert(ischar(value), ...
                    'Value for key.%s must be a string', field{1})
                value = sprintf('''%s''', escapeString(value));
            else
                assert((isnumeric(value) || islogical(value)) && isscalar(value), ...
                    'Value for key.%s must be a numeric scalar', field{1});
                value=sprintf('%1.16g', value);
            end
            subcond = sprintf('%s AND `%s`=%s', subcond, field{1}, value);
        end
        subcond = subcond(min(6,end):end);  % strip " AND "
    end
end


function [limit, args] = makeLimitClause(varargin)
% makes the SQL limit clause from fetch() input arguments.
% If the last one or two inputs are numeric, a LIMIT clause is
% created.
args = varargin;
limit = '';
if nargin
    lastArg = varargin{end};
    if ischar(lastArg) && (strncmp(strtrim(varargin{end}), 'ORDER BY', 8) || strncmp(varargin{end}, 'LIMIT ', 6))
        limit = [' ' varargin{end}];
        args = args(1:end-1);
    elseif isnumeric(lastArg)
        limit = sprintf(' LIMIT %d', lastArg);
        args = args(1:end-1);
    end
end
end


function str = escapeString(str)
% Escapes strings that are used in SQL clauses by struct2cond.
% We use ' to enclose strings, so we need to replace all instances of ' with ''.
% To prevent the expansion of MySQL escape characters, all instances
% of \ have to be replaced with \\.
str = strrep(str, '''', '''''');
str = strrep(str, '\', '\\');
end
