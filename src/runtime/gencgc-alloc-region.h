#ifndef _GENCGC_ALLOC_REGION_H_
#define _GENCGC_ALLOC_REGION_H_
/* Abstract out the data for an allocation region allowing a single
 * routine to be used for allocation and closing. */
struct alloc_region {

    /* These two are needed for quick allocation. */
    void  *free_pointer;
    void  *end_addr; /* pointer to the byte after the last usable byte */

    /* These are needed when closing the region. */
    int  first_page;
    int  last_page;
    void  *start_addr;
};

extern struct alloc_region  boxed_region;
extern struct alloc_region  unboxed_region;
extern int from_space, new_space;
extern struct weak_pointer *weak_pointers;

extern void *current_region_free_pointer;
extern void *current_region_end_addr;

#endif /*  _GENCGC_ALLOC_REGION_H_ */
