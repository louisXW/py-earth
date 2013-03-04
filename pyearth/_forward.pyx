# distutils: language = c
# cython: cdivision = True
# cython: boundscheck = False
# cython: wraparound = False
# cython: profile = True

from _util cimport reorderxby, fastr, update_uv, augmented_normal
from _basis cimport Basis, BasisFunction, ConstantBasisFunction, LinearBasisFunction, HingeBasisFunction
from _choldate cimport cholupdate, choldowndate
from _record cimport ForwardPassIteration

from libc.math cimport sqrt, abs, log, log2
import numpy as np
import scipy.linalg
cnp.import_array()
cdef class ForwardPasser:
    
    def __init__(ForwardPasser self, cnp.ndarray[FLOAT_t, ndim=2] X, cnp.ndarray[FLOAT_t, ndim=1] y, **kwargs):
        cdef unsigned int i
        cdef FLOAT_t sst
        self.X = X
        self.y = y
        self.m = self.X.shape[0]
        self.n = self.X.shape[1]
        self.endspan = kwargs['endspan'] if 'endspan' in kwargs else -1
        self.minspan = kwargs['minspan'] if 'minspan' in kwargs else -1
        self.endspan_alpha = kwargs['endspan_alpha'] if 'endspan_alpha' in kwargs else .05
        self.minspan_alpha = kwargs['minspan_alpha'] if 'minspan_alpha' in kwargs else .05
        self.max_terms = kwargs['max_terms'] if 'max_terms' in kwargs else 10
        self.max_degree = kwargs['max_degree'] if 'max_degree' in kwargs else 1
        self.thresh = kwargs['thresh'] if 'thresh' in kwargs else 0.001
        self.penalty = kwargs['penalty'] if 'penalty' in kwargs else 3.0
        self.check_every = kwargs['check_every'] if 'check_every' in kwargs else -1
        self.min_search_points = kwargs['min_search_points'] if 'min_search_points' in kwargs else 100
        self.xlabels = kwargs['xlabels'] if 'xlabels' in kwargs else ['x'+str(i) for i in range(self.n)]
        if self.check_every < 0:
            self.check_every = <int> (self.m / self.min_search_points) if self.m > self.min_search_points else 1
        self.sst = np.dot(self.y,self.y)/self.m
        self.record = ForwardPassRecord(self.m,self.n,self.penalty,self.sst)
        self.basis = Basis()
        self.basis.append(ConstantBasisFunction())
        
        self.sorting = np.empty(shape=self.m, dtype=int)
        self.mwork = np.empty(shape=self.m, dtype=int)
        self.delta = np.empty(shape=self.m, dtype=float)
        self.u = np.empty(shape=self.max_terms, dtype=float)
        self.B_orth_times_parent_cum = np.empty(shape=self.max_terms,dtype=np.float)
        self.B = np.ones(shape=(self.m,self.max_terms), order='C',dtype=np.float)
        self.B_orth = np.ones(shape=(self.m,self.max_terms), order='C',dtype=np.float)
        self.u = np.empty(shape=self.max_terms, dtype=np.float)
        self.c = np.empty(shape=self.max_terms, dtype=np.float)
        self.c_squared = 0.0
        self.sort_tracker = np.empty(shape=self.m, dtype=int)
        for i in range(self.m):
            self.sort_tracker[i] = i
        self.zero_tol = 1e-8
        
        #Initialize B_orth, c, and c_squared (assuming column 0 of B_orth is already filled with 1)
        self.orthonormal_update(0)
    
    cpdef Basis get_basis(ForwardPasser self):
        return self.basis
    
    def get_B_orth(ForwardPasser self):
        return self.B_orth
    
    cpdef run(ForwardPasser self):
        cdef unsigned int i
        while True:
            self.next_pair()
            if self.stop_check():
                break

    cdef stop_check(ForwardPasser self):
        last = self.record.__len__() - 1
        if self.record.iterations[last].get_size() + 2 > self.max_terms:
            self.record.stopping_condition = MAXTERMS
            return True
        rsq = self.record.rsq(last)
        if rsq > 1 - self.thresh:
            self.record.stopping_condition = MAXRSQ
            return True
        previous_rsq = self.record.rsq(last - 1)
        if rsq - previous_rsq < self.thresh:
            self.record.stopping_condition = NOIMPRV
            return True
        if self.record.grsq(last) < -10:
            self.record.stopping_condition = LOWGRSQ
            return True
        return False
    
    cpdef int orthonormal_update(ForwardPasser self, unsigned int k):
        '''Orthogonalize and normalize column k of B_orth against all previous columns of B_orth.'''
        #Currently implemented using modified Gram-Schmidt process
        #TODO: Optimize - replace calls to numpy with calls to blas
        
        cdef cnp.ndarray[FLOAT_t, ndim=2] B_orth = <cnp.ndarray[FLOAT_t, ndim=2]> self.B_orth
        cdef cnp.ndarray[FLOAT_t, ndim=1] c = <cnp.ndarray[FLOAT_t, ndim=1]> self.c
        cdef cnp.ndarray[FLOAT_t, ndim=1] y = <cnp.ndarray[FLOAT_t, ndim=1]> self.y
        
        cdef unsigned int i
        
        #Orthogonalize
        if k > 0:
            for i in range(k):
                B_orth[:,k] -= B_orth[:,i] * (np.dot(B_orth[:,k],B_orth[:,i]) / np.dot(B_orth[:,i],B_orth[:,i]))
        
        #Normalize
        nrm = sqrt(np.dot(B_orth[:,k],B_orth[:,k]))
        if nrm <= self.zero_tol:
            B_orth[:,k] = 0
            c[k] = 0
            return 1 #The new column is in the column space of the previous columns
        B_orth[:,k] /= nrm
        
        #Update c
        c[k] = np.dot(B_orth[:,k],y)
        self.c_squared += c[k]**2
        
        return 0 #No problems
    
    cpdef orthonormal_downdate(ForwardPasser self, unsigned int k):
        '''
        Undo the effects of the last orthonormal update.  You can only undo the last orthonormal update this way.
        There will be no warning of any kind if you mess this up.  You'll just get wrong answers.
        In reality, all this does is downdate c_squared (the elements of c and B_orth are left alone, since they
        can simply be ignored until they are overwritten).
        '''
        self.c_squared -= self.c[k]**2
        
    def trace(self):
        return self.record
        
    cdef next_pair(ForwardPasser self):
        cdef unsigned int variable
        cdef unsigned int parent_idx
        cdef unsigned int parent_degree
        cdef unsigned int nonzero_count
        cdef BasisFunction parent
        cdef cnp.ndarray[INT_t,ndim=1] candidates_idx
        cdef FLOAT_t knot
        cdef FLOAT_t mse
        cdef unsigned int knot_idx
        cdef FLOAT_t knot_choice
        cdef FLOAT_t mse_choice
        cdef int knot_idx_choice
        cdef unsigned int parent_idx_choice
        cdef BasisFunction parent_choice
        cdef unsigned int variable_choice
        cdef bint first = True
        cdef BasisFunction bf1
        cdef BasisFunction bf2
        cdef unsigned int k = len(self.basis)
        cdef unsigned int endspan
        cdef bint linear_dependence
        cdef bint dependent
        
        cdef cnp.ndarray[FLOAT_t,ndim=2] X = <cnp.ndarray[FLOAT_t,ndim=2]> self.X
        cdef cnp.ndarray[FLOAT_t,ndim=2] B = <cnp.ndarray[FLOAT_t,ndim=2]> self.B
        cdef cnp.ndarray[FLOAT_t,ndim=2] B_orth = <cnp.ndarray[FLOAT_t,ndim=2]> self.B_orth
        cdef cnp.ndarray[FLOAT_t,ndim=1] y = <cnp.ndarray[FLOAT_t,ndim=1]> self.y
        
        if self.endspan < 0:
            endspan = round(3 - log2(self.endspan_alpha/self.n))
        
        #Iterate over variables
        for variable in range(self.n):
            
            #Sort the data
            self.sorting[:] = np.argsort(X[:,variable])[::-1] #TODO: eliminate Python call / data copy
            reorderxby(X,B,B_orth,y,self.sorting,self.sort_tracker)
            
            #Iterate over parents
            for parent_idx in range(k):
                linear_dependence = False
                
                parent = self.basis.get(parent_idx)
                if self.max_degree >= 0:
                    parent_degree = parent.degree()
                    if parent_degree >= self.max_degree:
                        continue
                if not parent.is_splittable():
                    continue
                
                #Add the linear term to B
                B[:,k] = B[:,parent_idx]*X[:,variable] #TODO: Optimize
                
                #Find the valid knot candidates
                candidates_idx = parent.valid_knots(B[:,parent_idx], X[:,variable], variable, self.check_every, endspan, self.minspan, self.minspan_alpha, self.n, self.mwork)

                #Choose the best candidate (if no candidate is an improvement on the linear term, knot_idx is left as -1)
                if len(candidates_idx) > 0:

                    #Orthonormalize
                    B_orth[:,k] = B[:,k]
                    self.orthonormal_update(k)
                    
                    #Find the best knot location for this parent and variable combination
                    self.best_knot(parent_idx,variable,k,candidates_idx,&mse,&knot,&knot_idx)
                    
                    #Do and orthonormal downdate
                    self.orthonormal_downdate(k)
                else:
                    continue
                
                #Update the choices
                if first:
                    knot_choice = knot
                    mse_choice = mse
                    knot_idx_choice = knot_idx
                    parent_idx_choice = parent_idx
                    parent_choice = parent
                    variable_choice = variable
                    first = False
                    dependent = linear_dependence
                if mse < mse_choice:
                    knot_choice = knot
                    mse_choice = mse
                    knot_idx_choice = knot_idx
                    parent_idx_choice = parent_idx
                    parent_choice = parent
                    variable_choice = variable
                    dependent = linear_dependence
                    
        #Add the new basis functions
        parent = self.basis.get(parent_idx)
        label = self.xlabels[variable_choice]
        if not dependent:
            bf1 = HingeBasisFunction(parent_choice,knot_choice,knot_idx_choice,variable_choice,False,label)
            bf2 = HingeBasisFunction(parent_choice,knot_choice,knot_idx_choice,variable_choice,True,label)
            bf1.apply(X,B[:,k])
            bf2.apply(X,B[:,k+1])
            self.basis.append(bf1)
            self.basis.append(bf2)
            #Orthogonalize the new basis
            B_orth[:,k] = B[:,k]
            if self.orthonormal_update(k) == 1:
                bf1.make_unsplittable()
            B_orth[:,k+1] = B[:,k+1]
            if self.orthonormal_update(k+1) == 1:
                bf2.make_unsplittable()
        else:
            bf1 = HingeBasisFunction(parent_choice,knot_choice,knot_idx_choice,variable_choice,False,label)
            bf1.apply(X,B[:,k])
            self.basis.append(bf1)
            #Orthogonalize the new basis
            B_orth[:,k] = B[:,k]
            if self.orthonormal_update(k) == 1:
                bf1.make_unsplittable()
            
        #TODO: Undo the sorting
        
        #Update the build record
        self.record.append(ForwardPassIteration(parent_idx_choice,variable_choice,knot_idx_choice,mse_choice,len(self.basis)))
        
    cdef best_knot(ForwardPasser self, unsigned int parent, unsigned int variable, unsigned int k, cnp.ndarray[INT_t,ndim=1] candidates, FLOAT_t * mse, FLOAT_t * knot, unsigned int * knot_idx):
        '''
        Find the best knot location (in terms of squared error).
        
        Assumes:
        B[:,k] is the linear term for variable
        X[:,variable] is in decreasing order
        candidates is in increasing order (it is an array of indices into X[:,variable]
        mse is a pointer to the mean squared error of including just the linear term in B[:,k]
        '''
        
        cdef cnp.ndarray[FLOAT_t, ndim=1] b = <cnp.ndarray[FLOAT_t, ndim=1]> self.B[:,k+1]
        cdef cnp.ndarray[FLOAT_t, ndim=1] b_parent = <cnp.ndarray[FLOAT_t, ndim=1]> self.B[:,parent]
        cdef cnp.ndarray[FLOAT_t, ndim=1] u = <cnp.ndarray[FLOAT_t, ndim=1]> self.u
        cdef cnp.ndarray[FLOAT_t, ndim=2] B_orth = <cnp.ndarray[FLOAT_t, ndim=2]> self.B_orth
        cdef cnp.ndarray[FLOAT_t, ndim=2] X = <cnp.ndarray[FLOAT_t, ndim=2]> self.X
        cdef cnp.ndarray[FLOAT_t, ndim=1] y = <cnp.ndarray[FLOAT_t, ndim=1]> self.y
        cdef cnp.ndarray[FLOAT_t, ndim=1] c = <cnp.ndarray[FLOAT_t, ndim=1]> self.c
        cdef cnp.ndarray[FLOAT_t, ndim=1] delta_b = <cnp.ndarray[FLOAT_t, ndim=1]> self.delta
        cdef cnp.ndarray[FLOAT_t, ndim=1] B_orth_times_parent_cum = <cnp.ndarray[FLOAT_t, ndim=1]> self.B_orth_times_parent_cum
        
        cdef cnp.ndarray[FLOAT_t, ndim=2] B = <cnp.ndarray[FLOAT_t, ndim=2]> self.B
        
        cdef unsigned int num_candidates = candidates.shape[0]
        
        cdef unsigned int i
        cdef unsigned int j
        cdef FLOAT_t u_end
        cdef FLOAT_t c_end
        cdef FLOAT_t z_end_squared
        cdef unsigned int candidate_idx
        cdef unsigned int last_candidate_idx
        cdef unsigned int last_last_candidate_idx
        cdef unsigned int best_candidate_idx
        cdef FLOAT_t candidate
        cdef FLOAT_t last_candidate
        cdef FLOAT_t best_candidate
        cdef FLOAT_t best_z_end_squared
        cdef FLOAT_t y_cum
        cdef FLOAT_t b_times_parent_cum
        cdef FLOAT_t diff
        cdef FLOAT_t delta_b_squared
        cdef FLOAT_t delta_c_end
        cdef FLOAT_t delta_u_end
        cdef FLOAT_t parent_squared_cum
        cdef FLOAT_t parent_times_y_cum
        
        #Compute the initial basis function
        candidate_idx = candidates[0]
        candidate = X[candidate_idx,variable]
        for i in range(self.m):#TODO: Vectorize?
            b[i] = 0
        for i in range(self.m):
            float_tmp = X[i,variable] - candidate
            if float_tmp > 0:
                b[i] = b_parent[i]*float_tmp
            else:
                break
            
        #Put b into the last column of B_orth
        for i in range(self.m):
            B_orth[i,k+1] = b[i]
        
        #Compute the initial covariance column, u (not including the final element)
        u[0:k+1] = np.dot(b,B_orth[:,0:k+1])
        
        #Compute the new last elements of c and u
        c_end = np.dot(b,y)
        u_end = np.dot(b,b)
        
        #Compute the last element of z (the others are identical to c)
        z_end_squared = ((c_end - np.dot(u[0:k+1],c[0:k+1]))**2) / (u_end - np.dot(u[0:k+1],u[0:k+1]))
        
        #Minimizing the norm is actually equivalent to maximizing z_end_squared
        #Store z_end_squared and the current candidate as the best knot choice
        best_z_end_squared = z_end_squared
        best_candidate_idx = candidate_idx
        best_candidate = candidate
        
        #Initialize the delta vector to 0
        for i in range(self.m):
            delta_b[i] = 0 #TODO: BLAS
        
        #Initialize the accumulators
        last_candidate_idx = 0
        y_cum = y[0]
        B_orth_times_parent_cum[0:k+1] = B_orth[0,0:k+1] * b_parent[0]
        b_times_parent_cum = b[0] * b_parent[0]
        parent_squared_cum = b_parent[0] ** 2
        parent_times_y_cum = b_parent[0] * y[0]
        
        #Now loop over the remaining candidates and update z_end_squared for each, looking for the greatest value
        for i in range(1,num_candidates):
            
            #Update the candidate
            last_last_candidate_idx = last_candidate_idx
            last_candidate_idx = candidate_idx
            last_candidate = candidate
            candidate_idx = candidates[i]
            candidate = X[candidate_idx,variable]
            
            #Update the accumulators and compute delta_b
            diff = last_candidate - candidate
            delta_c_end = 0.0
            
            #What follows is a section of code that has been optimized for speed at the expense of 
            #some readability.  To make it easier to understand this code in the future, I have included a 
            #"simple" block that implements the same math in a more straightforward (but much less efficient) 
            #way.  The (commented out) code between "BEGIN SIMPLE" and "END SIMPLE" should produce the same 
            #output as the code between "BEGIN HYPER-OPTIMIZED" and "END HYPER-OPTIMIZED".
            
            #BEGIN SIMPLE
#            #Calculate delta_b
#            for j  in range(0,last_candidate_idx+1):
#                delta_b[j] = diff
#            for j in range(last_candidate_idx+1,candidate_idx):
#                float_tmp = (X[j,variable] - candidate) * b_parent[j]
#                delta_b[j] = float_tmp
#            
#            #Update u and z_end_squared
#            u[0:k+1] += np.dot(delta_b,B_orth[:,0:k+1])
#            u_end += 2*np.dot(delta_b,b) + np.dot(delta_b, delta_b)
#            
#            #Update c_end
#            c_end += np.dot(delta_b,y)
#            
#            #Update z_end_squared
#            z_end_squared = ((c_end - np.dot(u[0:k+1],c[0:k+1]))**2) / (u_end)
#            
#            #Update b
#            b += delta_b
            #END SIMPLE
            
            #BEGIN HYPER-OPTIMIZED
            delta_b_squared = 0.0
            delta_c_end = 0.0
            delta_u_end = 0.0
            for j in range(last_last_candidate_idx+1,last_candidate_idx+1):
                y_cum += y[j]
                for h in range(k+1):#TODO: BLAS
                    B_orth_times_parent_cum[h] += B_orth[j,h]*b_parent[j]
                b_times_parent_cum += b[j]*b_parent[j]
                parent_squared_cum += b_parent[j] ** 2
                parent_times_y_cum += b_parent[j] * y[j]
            delta_c_end += diff * parent_times_y_cum
            delta_u_end += 2*diff * b_times_parent_cum
            delta_b_squared = (diff**2)*parent_squared_cum
            for j in range(last_candidate_idx+1,candidate_idx):
                float_tmp = (X[j,variable] - candidate) * b_parent[j]
                delta_b[j] = float_tmp
                delta_b_squared += float_tmp**2
                delta_c_end += float_tmp * y[j]
                delta_u_end += 2*float_tmp*b[j]
            
            #Update u_end
            delta_u_end += delta_b_squared
            u_end += delta_u_end
            
            #Update c_end
            c_end += delta_c_end
            
            #Update u
            u[0:k+1] += np.dot(delta_b[last_candidate_idx+1:candidate_idx],B_orth[last_candidate_idx+1:candidate_idx,0:k+1]) #TODO: BLAS
            u[0:k+1] += diff*B_orth_times_parent_cum[0:k+1]
            
            #Update b and b_times_parent_cum
            b[last_candidate_idx+1:candidate_idx] += delta_b[last_candidate_idx+1:candidate_idx]
            b_times_parent_cum += parent_squared_cum * diff
            
            #Compute the new z_end_squared (this is the quantity we're optimizing)
            z_end_squared = ((c_end - np.dot(u[0:k+1],c[0:k+1]))**2) / (u_end - np.dot(u[0:k+1],u[0:k+1]))
            #END HYPER-OPTIMIZED
            
            #Update the best if necessary
            if z_end_squared > best_z_end_squared:
                best_z_end_squared = z_end_squared
                best_candidate_idx = candidate_idx
                best_candidate = candidate
            
        #Compute the mse for the best z_end and set return values
        mse[0] = self.sst - ((self.c_squared + best_z_end_squared)/self.m)
        knot[0] = best_candidate
        knot_idx[0] = best_candidate_idx

    